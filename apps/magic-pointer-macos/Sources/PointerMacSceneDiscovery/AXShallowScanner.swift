@preconcurrency import ApplicationServices
import Dispatch
import Foundation
import PointerSceneContracts

enum AXObserverElementProfile: UInt8, Hashable, Sendable {
    case application
    case element
}

struct AXObserverElementSpec: @unchecked Sendable {
    let processID: Int32
    let objectID: SourceObjectID
    let element: AXUIElement
    let profile: AXObserverElementProfile
}

struct AXScannedNode: @unchecked Sendable {
    let processID: Int32
    let objectID: SourceObjectID
    let parentObjectID: SourceObjectID?
    let element: AXUIElement
    let profile: AXObserverElementProfile
    let role: String
    let subrole: String?
    let bounds: MacGlobalRect?
    let sensitivity: SceneDataSensitivity
}

struct AXHierarchyScanResult: Sendable {
    let permissionTrusted: Bool
    let nodes: [AXScannedNode]
    let observations: [SceneObservation]
    let observerElements: [AXObserverElementSpec]
}

/// Source-local identity table. It is owned exclusively by the proactive scan
/// thread and intentionally shares no state, cache, or identifiers with the live
/// AXSemanticResolver used by pointer verification and actions.
final class AXSceneIdentityRegistry: @unchecked Sendable {
    private struct Entry {
        let processID: Int32
        let objectID: SourceObjectID
        let element: AXUIElement
        var lastSeenOrdinal: UInt64
    }

    private let capacity: Int
    private var buckets: [Int: [Entry]] = [:]
    private var count = 0
    private var ordinal: UInt64 = 0
    private var evictedObjectIDs: [SourceObjectID] = []

    init(capacity: Int = 1_024) {
        precondition(capacity >= 128)
        self.capacity = capacity
    }

    func objectID(for element: AXUIElement, processID: Int32) -> SourceObjectID {
        ordinal = ordinal == UInt64.max ? 1 : ordinal + 1
        let hash = Int(CFHash(element))
        if var entries = buckets[hash],
           let index = entries.firstIndex(where: {
               $0.processID == processID && CFEqual($0.element, element)
           })
        {
            entries[index].lastSeenOrdinal = ordinal
            let objectID = entries[index].objectID
            buckets[hash] = entries
            return objectID
        }

        if count >= capacity {
            if let evicted = evictOldest() {
                evictedObjectIDs.append(evicted)
            }
        }
        let objectID = SourceObjectID()
        buckets[hash, default: []].append(Entry(
            processID: processID,
            objectID: objectID,
            element: element,
            lastSeenOrdinal: ordinal
        ))
        count += 1
        return objectID
    }

    func existingObjectID(for element: AXUIElement, processID: Int32) -> SourceObjectID? {
        let hash = Int(CFHash(element))
        return buckets[hash]?.first(where: {
            $0.processID == processID && CFEqual($0.element, element)
        })?.objectID
    }

    func remove(_ element: AXUIElement, processID: Int32) -> SourceObjectID? {
        let hash = Int(CFHash(element))
        guard var entries = buckets[hash],
              let index = entries.firstIndex(where: {
                  $0.processID == processID && CFEqual($0.element, element)
              })
        else {
            return nil
        }
        let removed = entries.remove(at: index)
        count -= 1
        buckets[hash] = entries.isEmpty ? nil : entries
        return removed.objectID
    }

    @discardableResult
    func removeAll(processID: Int32) -> [SourceObjectID] {
        var removedObjectIDs: [SourceObjectID] = []
        for key in Array(buckets.keys) {
            guard let entries = buckets[key] else { continue }
            let retained = entries.filter { $0.processID != processID }
            removedObjectIDs.append(contentsOf: entries.lazy.filter {
                $0.processID == processID
            }.map(\.objectID))
            count -= entries.count - retained.count
            buckets[key] = retained.isEmpty ? nil : retained
        }
        return removedObjectIDs
    }

    /// A checkpoint is a replacement projection. Identities it omits are
    /// permanently retired by scene memory, so the source registry must forget
    /// them as well rather than reissuing a retired ID if an element reappears.
    @discardableResult
    func removeIdentitiesOmitted(
        byCheckpointRetaining retainedObjectIDs: Set<SourceObjectID>
    ) -> [SourceObjectID] {
        var removedObjectIDs: [SourceObjectID] = []
        for key in Array(buckets.keys) {
            guard let entries = buckets[key] else { continue }
            let retained = entries.filter { retainedObjectIDs.contains($0.objectID) }
            removedObjectIDs.append(contentsOf: entries.lazy.filter {
                !retainedObjectIDs.contains($0.objectID)
            }.map(\.objectID))
            count -= entries.count - retained.count
            buckets[key] = retained.isEmpty ? nil : retained
        }
        return removedObjectIDs
    }

    /// Evictions are consumed by the scan runtime before it reads or writes its
    /// observation cache again, keeping both bounded identity views coupled.
    func drainEvictedObjectIDs() -> [SourceObjectID] {
        let result = evictedObjectIDs
        evictedObjectIDs.removeAll(keepingCapacity: true)
        return result
    }

    var entryCount: Int { count }

    private func evictOldest() -> SourceObjectID? {
        var candidate: (hash: Int, index: Int, ordinal: UInt64)?
        for (hash, entries) in buckets {
            for (index, entry) in entries.enumerated() {
                if candidate == nil || entry.lastSeenOrdinal < candidate!.ordinal {
                    candidate = (hash, index, entry.lastSeenOrdinal)
                }
            }
        }
        guard let candidate, var entries = buckets[candidate.hash] else { return nil }
        let removed = entries.remove(at: candidate.index)
        count -= 1
        buckets[candidate.hash] = entries.isEmpty ? nil : entries
        return removed.objectID
    }
}

final class AXShallowScanner: @unchecked Sendable {
    private struct PendingNode {
        let element: AXUIElement
        let processID: Int32
        let parentObjectID: SourceObjectID?
        let inheritedSensitivity: SceneDataSensitivity?
        let depth: Int
    }

    private struct CoreFields {
        let role: String
        let subrole: String?
        let position: CGPoint?
        let size: CGSize?
    }

    private let device: DevicePrincipalID
    private let sourceEpoch: SceneSourceEpoch
    private let maximumDepth: Int
    private let maximumObjects: Int
    private let maximumScanDurationNs: UInt64
    private let perCallTimeoutSeconds: Float

    init(
        device: DevicePrincipalID,
        sourceEpoch: SceneSourceEpoch,
        maximumDepth: Int = 2,
        maximumObjects: Int = 128,
        maximumScanDurationNs: UInt64 = 750_000_000,
        perCallTimeoutSeconds: Float = 0.04
    ) {
        precondition((0 ... 2).contains(maximumDepth))
        precondition((1 ... 128).contains(maximumObjects))
        self.device = device
        self.sourceEpoch = sourceEpoch
        self.maximumDepth = maximumDepth
        self.maximumObjects = maximumObjects
        self.maximumScanDurationNs = maximumScanDurationNs
        self.perCallTimeoutSeconds = perCallTimeoutSeconds
    }

    func scanApplications(
        processIDs: [Int32],
        coordinateSnapshot: MacDesktopCoordinateSnapshot?,
        registry: AXSceneIdentityRegistry,
        observedAt: UInt64
    ) -> AXHierarchyScanResult {
        guard AXIsProcessTrusted() else {
            return AXHierarchyScanResult(
                permissionTrusted: false,
                nodes: [],
                observations: [],
                observerElements: []
            )
        }

        let deadline = DispatchTime.now().uptimeNanoseconds &+ maximumScanDurationNs
        var budget = AXShallowScanBudget(
            maximumDepth: maximumDepth,
            maximumObjects: maximumObjects
        )
        let pendingRoots = processIDs.map {
            PendingNode(
                element: AXUIElementCreateApplication(pid_t($0)),
                processID: $0,
                parentObjectID: nil,
                inheritedSensitivity: nil,
                depth: 0
            )
        }
        var pending = pendingRoots
        let rootObserverElements = pendingRoots.map {
            AXObserverElementSpec(
                processID: $0.processID,
                objectID: registry.objectID(for: $0.element, processID: $0.processID),
                element: $0.element,
                profile: .application
            )
        }
        var cursor = 0
        var nodes: [AXScannedNode] = []
        nodes.reserveCapacity(min(maximumObjects, pending.count * 16))
        var seenObjectIDs = Set<SourceObjectID>()
        var permissionLost = false

        while cursor < pending.count,
              DispatchTime.now().uptimeNanoseconds < deadline
        {
            let item = pending[cursor]
            cursor += 1
            guard budget.consume(depth: item.depth) else { continue }
            guard let node = readNode(
                item,
                registry: registry,
                permissionLost: &permissionLost
            ) else {
                continue
            }
            guard seenObjectIDs.insert(node.objectID).inserted else { continue }
            nodes.append(node)

            guard item.depth < maximumDepth,
                  budget.remainingObjects > 0,
                  DispatchTime.now().uptimeNanoseconds < deadline
            else {
                continue
            }
            let children = boundedChildren(
                of: item.element,
                limit: budget.remainingObjects,
                permissionLost: &permissionLost
            )
            pending.append(contentsOf: children.map {
                PendingNode(
                    element: $0.rawValue,
                    processID: item.processID,
                    parentObjectID: node.objectID,
                    inheritedSensitivity: node.sensitivity,
                    depth: item.depth + 1
                )
            })
        }

        let trusted = !permissionLost && AXIsProcessTrusted()
        let observations = trusted
            ? nodes.compactMap {
                try? observation(
                    for: $0,
                    coordinateSnapshot: coordinateSnapshot,
                    observedAt: observedAt
                )
            }
            : []
        return AXHierarchyScanResult(
            permissionTrusted: trusted,
            nodes: trusted ? nodes : [],
            observations: observations,
            observerElements: trusted ? rootObserverElements : []
        )
    }

    func scanElement(
        _ element: AXUIElement,
        processID: Int32,
        parentObjectID: SourceObjectID? = nil,
        inheritedSensitivity: SceneDataSensitivity? = nil,
        coordinateSnapshot: MacDesktopCoordinateSnapshot?,
        registry: AXSceneIdentityRegistry,
        observedAt: UInt64
    ) -> AXHierarchyScanResult {
        guard AXIsProcessTrusted() else {
            return AXHierarchyScanResult(
                permissionTrusted: false,
                nodes: [],
                observations: [],
                observerElements: []
            )
        }
        var permissionLost = false
        let pending = PendingNode(
            element: element,
            processID: processID,
            parentObjectID: parentObjectID,
            inheritedSensitivity: inheritedSensitivity,
            depth: 0
        )
        guard let node = readNode(
            pending,
            registry: registry,
            permissionLost: &permissionLost
        ), !permissionLost, AXIsProcessTrusted()
        else {
            return AXHierarchyScanResult(
                permissionTrusted: !permissionLost && AXIsProcessTrusted(),
                nodes: [],
                observations: [],
                observerElements: []
            )
        }
        let observation = try? observation(
            for: node,
            coordinateSnapshot: coordinateSnapshot,
            observedAt: observedAt
        )
        return AXHierarchyScanResult(
            permissionTrusted: true,
            nodes: [node],
            observations: observation.map { [$0] } ?? [],
            observerElements: [AXObserverElementSpec(
                processID: node.processID,
                objectID: node.objectID,
                element: node.element,
                profile: node.profile
            )]
        )
    }

    private func readNode(
        _ pending: PendingNode,
        registry: AXSceneIdentityRegistry,
        permissionLost: inout Bool
    ) -> AXScannedNode? {
        AXUIElementSetMessagingTimeout(pending.element, perCallTimeoutSeconds)
        let attributes = AXStructuralAttributePolicy.attributeNames.map { $0 as CFString }
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            pending.element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        )
        if error == .apiDisabled {
            permissionLost = true
            return nil
        }
        guard error == .success, let raw = values as? [Any] else { return nil }

        let core = CoreFields(
            role: string(at: 0, in: raw) ?? (kAXUnknownRole as String),
            subrole: string(at: 1, in: raw),
            position: point(at: 2, in: raw),
            size: size(at: 3, in: raw)
        )
        let sensitivity = AXSceneSensitivityPropagation.combine(
            parent: pending.inheritedSensitivity,
            local: AXStructuralAttributePolicy.contentSensitivity(subrole: core.subrole)
        )
        let bounds = core.position.flatMap { position in
            core.size.flatMap { size in
                MacGlobalRect(
                    x: Double(position.x),
                    y: Double(position.y),
                    width: Double(size.width),
                    height: Double(size.height)
                )
            }
        }
        let objectID = registry.objectID(
            for: pending.element,
            processID: pending.processID
        )
        return AXScannedNode(
            processID: pending.processID,
            objectID: objectID,
            parentObjectID: pending.parentObjectID,
            element: pending.element,
            profile: pending.depth == 0 ? .application : .element,
            role: core.role,
            subrole: core.subrole,
            bounds: bounds,
            sensitivity: sensitivity
        )
    }

    private func boundedChildren(
        of element: AXUIElement,
        limit: Int,
        permissionLost: inout Bool
    ) -> [AXRetainedElement] {
        let visible = copyElements(
            element,
            attribute: kAXVisibleChildrenAttribute as CFString,
            limit: limit,
            permissionLost: &permissionLost
        )
        let all = copyElements(
            element,
            attribute: kAXChildrenAttribute as CFString,
            limit: limit,
            permissionLost: &permissionLost
        )
        return AXVisibleChildOrder.prioritized(visible: visible, all: all, limit: limit)
    }

    private func copyElements(
        _ element: AXUIElement,
        attribute: CFString,
        limit: Int,
        permissionLost: inout Bool
    ) -> [AXRetainedElement] {
        guard limit > 0 else { return [] }
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, attribute, &count)
        if countError == .apiDisabled { permissionLost = true }
        guard countError == .success, count > 0 else { return [] }

        var rawValues: CFArray?
        let copyError = AXUIElementCopyAttributeValues(
            element,
            attribute,
            0,
            min(count, limit),
            &rawValues
        )
        if copyError == .apiDisabled { permissionLost = true }
        guard copyError == .success, let rawValues else { return [] }
        return (rawValues as NSArray).compactMap { value in
            let raw = value as CFTypeRef
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return AXRetainedElement(unsafeDowncast(raw, to: AXUIElement.self))
        }
    }

    func observation(
        for node: AXScannedNode,
        coordinateSnapshot: MacDesktopCoordinateSnapshot?,
        observedAt: UInt64
    ) throws -> SceneObservation {
        let subject = SourceObjectKey(sourceEpoch: sourceEpoch, objectID: node.objectID)
        var claims: [SceneFieldClaim] = [
            try claim(
                AXSceneField.objectKind,
                .text("accessibilityElement"),
                sensitivity: .ordinary
            ),
            try claim(
                AXSceneField.applicationPID,
                .signedInteger(Int64(node.processID)),
                sensitivity: .ordinary
            ),
            try claim(AXSceneField.role, .text(node.role), sensitivity: .ordinary),
        ]
        if let subrole = node.subrole {
            claims.append(try claim(
                AXSceneField.subrole,
                .text(subrole),
                sensitivity: .ordinary
            ))
        }
        if let bounds = node.bounds,
           let region = coordinateSnapshot?.mapQuartzGlobalRect(bounds)
        {
            claims.append(try claim(
                AXSceneField.geometryBounds,
                .region(region),
                sensitivity: .ordinary
            ))
        }
        claims.append(try claim(
            AXSceneField.content,
            nil,
            sensitivity: node.sensitivity
        ))
        return try SceneObservation(
            subject: subject,
            parent: node.parentObjectID.map {
                SourceObjectKey(sourceEpoch: sourceEpoch, objectID: $0)
            },
            observedAtSourceMonotonicNs: observedAt,
            claims: claims
        )
    }

    private func claim(
        _ field: SceneFieldKey,
        _ value: SceneFieldValue?,
        sensitivity: SceneDataSensitivity
    ) throws -> SceneFieldClaim {
        try SceneFieldClaim(
            field: field,
            value: value,
            knowledge: .observed,
            confidence: 1,
            sensitivity: sensitivity,
            evidence: [try SceneEvidence(kind: .accessibility)]
        )
    }

    private func string(at index: Int, in values: [Any]) -> String? {
        guard values.indices.contains(index) else { return nil }
        return values[index] as? String
    }

    private func point(at index: Int, in values: [Any]) -> CGPoint? {
        guard values.indices.contains(index) else { return nil }
        let raw = values[index] as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func size(at index: Int, in values: [Any]) -> CGSize? {
        guard values.indices.contains(index) else { return nil }
        let raw = values[index] as CFTypeRef
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

}

/// Proactive AX discovery deliberately reads only public structural attributes.
/// Human-authored title, description, identifier, and value strings remain out
/// of the observation pipeline because this layer cannot positively classify
/// them as ordinary before reading them.
enum AXStructuralAttributePolicy {
    static let attributeNames: [String] = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
    ]

    static func contentSensitivity(subrole: String?) -> SceneDataSensitivity {
        subrole == (kAXSecureTextFieldSubrole as String) ? .secure : .unknown
    }
}
