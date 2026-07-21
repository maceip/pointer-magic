import Foundation
import PointerSceneContracts

public enum MacDesktopCoordinateRegistryError: Error, Equatable, Sendable {
    case duplicateDisplayID(UInt32)
    case duplicateDisplayUUID(UUID)
    case missingDisplayRegistration(displayID: UInt32)
    case retainedDisplayIdentityLimitExceeded(maximum: Int, actual: Int)
    case revisionExhausted
}

/// An immutable view of one exact Quartz desktop topology. Mapping does no I/O and
/// never consults Accessibility, AppKit, CoreGraphics, or the mutable registry.
public struct MacDesktopCoordinateSnapshot: Sendable {
    public let device: DevicePrincipalID
    public let topologyRevision: UInt64
    public let virtualDesktop: MacDesktopCoordinateMapper.VirtualDesktopMapping
    public let displayMappings: [MacDesktopCoordinateMapper.DisplayMapping]

    private let mapper: MacDesktopCoordinateMapper

    init(device: DevicePrincipalID, mapper: MacDesktopCoordinateMapper) {
        self.device = device
        self.topologyRevision = mapper.virtualDesktop.descriptor.coordinateSpace.revision
        self.virtualDesktop = mapper.virtualDesktop
        self.displayMappings = mapper.mappings
        self.mapper = mapper
    }

    /// Maps a Quartz-global point into the canonical virtual-desktop space carried by
    /// this exact snapshot. The maximum X/Y edges are outside the desktop.
    public func mapQuartzGlobalPoint(
        _ point: MacGlobalPoint
    ) -> MacMappedSurfacePoint? {
        mapper.virtualDesktopPoint(for: point)
    }

    /// Maps an intersecting Quartz-global rectangle without clipping it. This preserves
    /// the real geometry of windows that are partially offscreen.
    public func mapQuartzGlobalRect(_ rect: MacGlobalRect) -> SurfaceRegion? {
        mapper.virtualDesktopRegion(for: rect)
    }

    public func displayFragments(
        forQuartzGlobalRect rect: MacGlobalRect
    ) -> [MacMappedSurfaceRegion] {
        mapper.fragments(for: rect)
    }
}

/// The one local authority for macOS desktop surface identity and coordinate revision.
/// Discovery sources share an instance; source epochs never participate in coordinate
/// identity. Updates are performed only by discovery workers after a census. Readers
/// receive an immutable snapshot and therefore never trigger census or AX work.
public final class MacDesktopCoordinateRegistry: @unchecked Sendable {
    /// A process-local session fails closed rather than forgetting a display's last
    /// coordinate revision and later reusing that revision for the same stable surface.
    /// Sixty-four is four times the live-display census ceiling.
    public static let maximumRetainedDisplayIdentities = 64

    private enum DisplayKey: Hashable, Sendable {
        case stable(UUID)
        case fallback(UInt32)
    }

    private struct CoordinateSignature: Hashable, Sendable {
        let bounds: MacGlobalRect
        let pixelWidth: Int
        let pixelHeight: Int
        let rotationQuarterTurns: UInt8
        let scaleFactor: Double
    }

    private struct DisplayState: Sendable {
        var signature: CoordinateSignature
        var surfaceID: SceneSurfaceID
        var revision: UInt64
        var active: Bool
    }

    private struct TopologyMember: Hashable, Sendable {
        let surfaceID: SceneSurfaceID
        let signature: CoordinateSignature
    }

    private struct ReconciliationCandidate: Sendable {
        let displayStates: [DisplayKey: DisplayState]
        let nextFallbackGeneration: UInt64
        let activeTopology: [TopologyMember]
        let virtualDesktopRevision: UInt64
        let snapshot: MacDesktopCoordinateSnapshot
    }

    public let device: DevicePrincipalID

    /// Writers remain strictly serialized so revision and fallback-generation
    /// decisions have one total order. Cache readers never acquire this lock.
    private let writerLock = NSLock()
    /// Protects only the immutable snapshot reference. The lock is never held while
    /// validating displays, reconciling identity, or constructing coordinate maps.
    private let publicationLock = NSLock()
    private let candidateConstructionHook: (@Sendable () -> Void)?
    private let retainedDisplayIdentityLimit: Int
    private let fallbackNamespace = UUID()
    private var nextFallbackGeneration: UInt64 = 1
    private var displayStates: [DisplayKey: DisplayState] = [:]
    private var activeTopology: [TopologyMember]?
    private var virtualDesktopRevision: UInt64 = 0
    private var currentSnapshot: MacDesktopCoordinateSnapshot?

    public init(device: DevicePrincipalID) {
        self.device = device
        self.candidateConstructionHook = nil
        self.retainedDisplayIdentityLimit = Self.maximumRetainedDisplayIdentities
    }

    init(
        device: DevicePrincipalID,
        candidateConstructionHook: @escaping @Sendable () -> Void,
        retainedDisplayIdentityLimit: Int =
            MacDesktopCoordinateRegistry.maximumRetainedDisplayIdentities
    ) {
        precondition(retainedDisplayIdentityLimit > 0)
        self.device = device
        self.candidateConstructionHook = candidateConstructionHook
        self.retainedDisplayIdentityLimit = retainedDisplayIdentityLimit
    }

    /// Reconciles already-captured display facts into the shared coordinate authority.
    /// This method performs bounded in-memory work only; it never captures the screen or
    /// calls a UI API. Exact repeated topologies return the same identities and revisions.
    @discardableResult
    public func update(
        with displays: [MacDisplaySnapshot]
    ) throws -> MacDesktopCoordinateSnapshot {
        writerLock.lock()
        defer { writerLock.unlock() }
        return try reconcileSerialized(displays)
    }

    /// Seeds the registry for a secondary source only when the primary workspace
    /// writer has not published a topology. The emptiness check and publication are
    /// atomic, so a slow secondary census cannot overwrite a newer workspace result.
    @discardableResult
    public func seedIfEmpty(
        with displays: [MacDisplaySnapshot]
    ) throws -> MacDesktopCoordinateSnapshot {
        writerLock.lock()
        defer { writerLock.unlock() }
        if let snapshot = publishedSnapshot() { return snapshot }
        return try reconcileSerialized(displays)
    }

    /// Requires `writerLock`. Candidate construction can be comparatively expensive,
    /// but publication remains a constant-time reference swap under its own lock.
    private func reconcileSerialized(
        _ displays: [MacDisplaySnapshot]
    ) throws -> MacDesktopCoordinateSnapshot {
        try validateUniqueDisplays(displays)
        candidateConstructionHook?()

        var candidateStates = displayStates
        var candidateGeneration = nextFallbackGeneration
        let incomingKeys = Set(displays.map(displayKey))
        let retainedIdentityCount = candidateStates.count +
            incomingKeys.subtracting(Set(candidateStates.keys)).count
        guard retainedIdentityCount <= retainedDisplayIdentityLimit else {
            throw MacDesktopCoordinateRegistryError.retainedDisplayIdentityLimitExceeded(
                maximum: retainedDisplayIdentityLimit,
                actual: retainedIdentityCount
            )
        }
        for key in candidateStates.keys where !incomingKeys.contains(key) {
            candidateStates[key]?.active = false
        }

        var registrations: [UInt32: MacDesktopDisplayCoordinateRegistration] = [:]
        registrations.reserveCapacity(displays.count)

        for display in displays.sorted(by: canonicalDisplayOrder) {
            let key = displayKey(display)
            let signature = coordinateSignature(display)
            let state: DisplayState

            switch key {
            case let .stable(uuid):
                if var existing = candidateStates[key] {
                    if !existing.active || existing.signature != signature {
                        existing.revision = try increment(existing.revision)
                    }
                    existing.signature = signature
                    existing.active = true
                    state = existing
                } else {
                    state = DisplayState(
                        signature: signature,
                        surfaceID: SceneSurfaceID(rawValue: uuid),
                        revision: 1,
                        active: true
                    )
                }
            case .fallback:
                if let existing = candidateStates[key],
                   existing.active,
                   existing.signature == signature
                {
                    state = existing
                } else {
                    let generation = candidateGeneration
                    candidateGeneration = try increment(candidateGeneration)
                    state = DisplayState(
                        signature: signature,
                        surfaceID: SceneStableIdentifiers.fallbackDisplay(
                            registryNamespace: fallbackNamespace,
                            displayID: display.displayID,
                            generation: generation
                        ),
                        revision: 1,
                        active: true
                    )
                }
            }

            candidateStates[key] = state
            registrations[display.displayID] = MacDesktopDisplayCoordinateRegistration(
                surfaceID: state.surfaceID,
                revision: state.revision
            )
        }

        let topology = displays.compactMap { display -> TopologyMember? in
            guard let registration = registrations[display.displayID] else { return nil }
            return TopologyMember(
                surfaceID: registration.surfaceID,
                signature: coordinateSignature(display)
            )
        }.sorted { lhs, rhs in
            lhs.surfaceID.rawValue.uuidString < rhs.surfaceID.rawValue.uuidString
        }

        var candidateVirtualRevision = virtualDesktopRevision
        if activeTopology != topology {
            candidateVirtualRevision = candidateVirtualRevision == 0
                ? 1
                : try increment(candidateVirtualRevision)
        }

        let mapper = try MacDesktopCoordinateMapper(
            displays: displays,
            device: device,
            virtualDesktopRevision: candidateVirtualRevision,
            displayRegistrations: registrations
        )
        let snapshot = MacDesktopCoordinateSnapshot(device: device, mapper: mapper)
        let candidate = ReconciliationCandidate(
            displayStates: candidateStates,
            nextFallbackGeneration: candidateGeneration,
            activeTopology: topology,
            virtualDesktopRevision: candidateVirtualRevision,
            snapshot: snapshot
        )
        commit(candidate)
        return snapshot
    }

    /// Requires `writerLock`. State is committed before publication while other
    /// writers remain excluded; readers see either the preceding immutable snapshot
    /// or the complete candidate, never partially reconciled state.
    private func commit(_ candidate: ReconciliationCandidate) {
        displayStates = candidate.displayStates
        nextFallbackGeneration = candidate.nextFallbackGeneration
        activeTopology = candidate.activeTopology
        virtualDesktopRevision = candidate.virtualDesktopRevision
        publish(candidate.snapshot)
    }

    /// Returns the last immutable topology without performing any discovery work.
    public func snapshot() -> MacDesktopCoordinateSnapshot? {
        publishedSnapshot()
    }

    /// Retires the current topology after an explicit sleep, lock, or failed display
    /// census. A later update cannot reuse an epoch-local fallback display identity.
    public func invalidateCurrentTopology() {
        writerLock.lock()
        for key in displayStates.keys {
            displayStates[key]?.active = false
        }
        activeTopology = nil
        publish(nil)
        writerLock.unlock()
    }

    /// Callers holding both locks always acquire writer then publication. Snapshot
    /// readers acquire only publication, so no inverse order or reader/writer cycle exists.
    private func publishedSnapshot() -> MacDesktopCoordinateSnapshot? {
        publicationLock.lock()
        let snapshot = currentSnapshot
        publicationLock.unlock()
        return snapshot
    }

    private func publish(_ snapshot: MacDesktopCoordinateSnapshot?) {
        publicationLock.lock()
        currentSnapshot = snapshot
        publicationLock.unlock()
    }

    private func validateUniqueDisplays(_ displays: [MacDisplaySnapshot]) throws {
        var displayIDs = Set<UInt32>()
        var displayUUIDs = Set<UUID>()
        for display in displays {
            guard displayIDs.insert(display.displayID).inserted else {
                throw MacDesktopCoordinateRegistryError.duplicateDisplayID(display.displayID)
            }
            if let uuid = display.displayUUID,
               !displayUUIDs.insert(uuid).inserted
            {
                throw MacDesktopCoordinateRegistryError.duplicateDisplayUUID(uuid)
            }
        }
    }

    private func displayKey(_ display: MacDisplaySnapshot) -> DisplayKey {
        if let uuid = display.displayUUID { return .stable(uuid) }
        return .fallback(display.displayID)
    }

    private func coordinateSignature(
        _ display: MacDisplaySnapshot
    ) -> CoordinateSignature {
        CoordinateSignature(
            bounds: display.globalBounds,
            pixelWidth: display.pixelWidth,
            pixelHeight: display.pixelHeight,
            rotationQuarterTurns: display.rotationQuarterTurns,
            scaleFactor: display.scaleFactor
        )
    }

    private func canonicalDisplayOrder(
        _ lhs: MacDisplaySnapshot,
        _ rhs: MacDisplaySnapshot
    ) -> Bool {
        switch (lhs.displayUUID, rhs.displayUUID) {
        case let (left?, right?) where left != right:
            return left.uuidString < right.uuidString
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return lhs.displayID < rhs.displayID
        }
    }

    private func increment(_ value: UInt64) throws -> UInt64 {
        guard value < UInt64.max else {
            throw MacDesktopCoordinateRegistryError.revisionExhausted
        }
        return value + 1
    }
}
