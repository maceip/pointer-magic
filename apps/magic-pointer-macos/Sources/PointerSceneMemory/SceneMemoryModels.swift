import Foundation
import PointerSceneContracts

/// Hard receiver-side bounds. Mutation-order eviction keeps the result deterministic
/// and independent of dictionary iteration order. Retired source epochs cannot be
/// evicted safely; reaching their cap fails future registration closed until a new
/// scene session creates a new memory store.
public struct SceneMemoryLimits: Hashable, Sendable {
    public let maximumRegisteredSources: Int
    public let maximumObjects: Int
    public let maximumFields: Int
    public let maximumEstimatedBytes: Int
    public let maximumReplayEntriesPerSource: Int
    public let maximumCoverageStreamsPerSource: Int
    public let maximumCoverageSilenceNs: UInt64
    public let maximumRetiredObjectIDsPerSource: Int
    public let maximumPrivacyRevisionFloorsPerSource: Int
    public let maximumRetiredSourceEpochs: Int

    public init(
        maximumRegisteredSources: Int = 64,
        maximumObjects: Int = 4_096,
        maximumFields: Int = 32_768,
        maximumEstimatedBytes: Int = 16 * 1_024 * 1_024,
        maximumReplayEntriesPerSource: Int = 4_096,
        maximumCoverageStreamsPerSource: Int = 128,
        maximumCoverageSilenceNs: UInt64 = 30_000_000_000,
        maximumRetiredObjectIDsPerSource: Int = 4_096,
        maximumPrivacyRevisionFloorsPerSource: Int = 4_096,
        maximumRetiredSourceEpochs: Int = 256
    ) throws {
        let values = [
            maximumRegisteredSources,
            maximumObjects,
            maximumFields,
            maximumEstimatedBytes,
            maximumReplayEntriesPerSource,
            maximumCoverageStreamsPerSource,
            maximumRetiredObjectIDsPerSource,
            maximumPrivacyRevisionFloorsPerSource,
            maximumRetiredSourceEpochs,
        ]
        guard values.allSatisfy({ $0 > 0 }), maximumCoverageSilenceNs > 0 else {
            throw SceneMemoryConfigurationError.invalidLimit
        }
        self.maximumRegisteredSources = maximumRegisteredSources
        self.maximumObjects = maximumObjects
        self.maximumFields = maximumFields
        self.maximumEstimatedBytes = maximumEstimatedBytes
        self.maximumReplayEntriesPerSource = maximumReplayEntriesPerSource
        self.maximumCoverageStreamsPerSource = maximumCoverageStreamsPerSource
        self.maximumCoverageSilenceNs = maximumCoverageSilenceNs
        self.maximumRetiredObjectIDsPerSource = maximumRetiredObjectIDsPerSource
        self.maximumPrivacyRevisionFloorsPerSource =
            maximumPrivacyRevisionFloorsPerSource
        self.maximumRetiredSourceEpochs = maximumRetiredSourceEpochs
    }

    public static var `default`: SceneMemoryLimits {
        // The literal defaults above are statically valid.
        try! SceneMemoryLimits()
    }
}

public enum SceneMemoryConfigurationError: Error, Equatable, Hashable, Sendable {
    case invalidLimit
}

/// Trusted receiver policy used to mint a non-serializable source grant and handle.
public struct SceneSourceGrantPolicy: Hashable, Sendable {
    public let capabilities: Set<SceneSourceCapability>
    public let eventKinds: Set<SceneEventKind>
    public let evidenceKinds: Set<SceneEvidenceKind>
    public let fields: SceneFieldGrant
    public let surfaces: SceneSurfaceGrant
    /// Receiver-selected stable source identities this source may cite as dependencies.
    /// Empty preserves the default authority: dependencies may cite only this source epoch.
    public let permittedDependencySources: Set<SceneSourceIdentity>
    public let expiresAtReceiverMonotonicNs: UInt64?

    public init(
        capabilities: Set<SceneSourceCapability>,
        eventKinds: Set<SceneEventKind>,
        evidenceKinds: Set<SceneEvidenceKind>,
        fields: SceneFieldGrant,
        surfaces: SceneSurfaceGrant,
        permittedDependencySources: Set<SceneSourceIdentity> = [],
        expiresAtReceiverMonotonicNs: UInt64? = nil
    ) {
        self.capabilities = capabilities
        self.eventKinds = eventKinds
        self.evidenceKinds = evidenceKinds
        self.fields = fields
        self.surfaces = surfaces
        self.permittedDependencySources = permittedDependencySources
        self.expiresAtReceiverMonotonicNs = expiresAtReceiverMonotonicNs
    }
}

public struct RegisteredSceneSource: Hashable, Sendable {
    public let manifest: SceneSourceManifest
    public let grant: SceneSourceGrant
    public let handle: SceneSourceHandle

    init(
        manifest: SceneSourceManifest,
        grant: SceneSourceGrant,
        handle: SceneSourceHandle
    ) {
        self.manifest = manifest
        self.grant = grant
        self.handle = handle
    }
}

public enum SceneSourceRegistrationError: Error, Equatable, Hashable, Sendable {
    case wrongSession
    case eventSchemaUnsupported
    case capabilityNotDeclared(SceneSourceCapability)
    case completeCoverageCapabilityRequired
    case expiredGrant
    case alreadyRegistered
    case retiredEpoch
    case retirementCapacityExhausted
    case sourceLimitReached
}

/// Receiver-created identity for an accepted source-local object incarnation.
public struct CanonicalSceneObjectID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum SceneFieldFreshness: String, Hashable, Sendable {
    case verifiedCurrent
    case provisional
    case stale
    case historical
    case unknown
}

public struct SceneFieldLookup: Hashable, Sendable {
    public let field: SceneFieldKey
    public let value: SceneFieldValue?
    public let knowledge: SceneClaimKnowledge?
    public let confidence: Double?
    public let sensitivity: SceneDataSensitivity
    public let evidence: [SceneEvidence]
    public let sourceRevision: SourceRevision?
    public let observedAtSourceMonotonicNs: UInt64?
    public let receivedAtReceiverMonotonicNs: UInt64?
    public let freshness: SceneFieldFreshness
}

public struct SceneObjectLookup: Hashable, Sendable {
    public let canonicalID: CanonicalSceneObjectID
    public let sourceObject: SourceObjectKey
    public let parent: SourceObjectKey?
    public let matchedRegion: SurfaceRegion?
    public let fields: [SceneFieldLookup]
}

public struct SceneSpatialLookup: Hashable, Sendable {
    public let coordinateSpace: SurfaceCoordinateSpace
    public let point: ScenePoint
    public let candidates: [SceneObjectLookup]
    public let examinedCandidates: Int
    public let examinationLimit: Int
    public let didTruncateCandidates: Bool
    public let didDropCandidates: Bool

    public var isComplete: Bool {
        !didTruncateCandidates && !didDropCandidates
    }
}

public struct SceneMemoryStatistics: Hashable, Sendable {
    public let registeredSources: Int
    public let sourceProjections: Int
    public let objects: Int
    public let fields: Int
    public let estimatedBytes: Int
    public let replayEntries: Int
    public let coverageStreams: Int
    public let privacyRevisionFloors: Int
}

/// Describes how the receiver derived a stacking hint. Direct window metadata is
/// preferred over an application-PID join so a window can never inherit the rank
/// of a different window owned by the same process.
public enum SceneHotSpatialStackingBasis: String, Hashable, Sendable {
    case directWindow
    case inferredApplicationWindow
}

public struct SceneHotSpatialCandidate: Hashable, Sendable {
    public let canonicalID: CanonicalSceneObjectID
    public let sourceObject: SourceObjectKey
    public let region: SurfaceRegion
    public let geometryField: SceneFieldKey
    public let evidenceKinds: Set<SceneEvidenceKind>
    public let receivedAtReceiverMonotonicNs: UInt64
    public let isHistorical: Bool
    /// True when the geometry's declared dependency is no longer current. The
    /// region remains available only as an explicitly stale first-paint fallback.
    public let isDependencyStale: Bool
    /// Lower values are nearer the front. `nil` is honest unknown state rather
    /// than an assumed background rank.
    public let frontToBackIndex: UInt64?
    public let stackingBasis: SceneHotSpatialStackingBasis?
    /// Ordinary, non-invalidated metadata carried for diagnostics. A candidate
    /// explicitly reported off-screen or fully transparent is not indexed at all.
    public let isOnScreen: Bool?
    public let alpha: Double?

    init(
        canonicalID: CanonicalSceneObjectID,
        sourceObject: SourceObjectKey,
        region: SurfaceRegion,
        geometryField: SceneFieldKey,
        evidenceKinds: Set<SceneEvidenceKind>,
        receivedAtReceiverMonotonicNs: UInt64,
        isHistorical: Bool,
        isDependencyStale: Bool,
        frontToBackIndex: UInt64?,
        stackingBasis: SceneHotSpatialStackingBasis?,
        isOnScreen: Bool?,
        alpha: Double?
    ) {
        self.canonicalID = canonicalID
        self.sourceObject = sourceObject
        self.region = region
        self.geometryField = geometryField
        self.evidenceKinds = evidenceKinds
        self.receivedAtReceiverMonotonicNs = receivedAtReceiverMonotonicNs
        self.isHistorical = isHistorical
        self.isDependencyStale = isDependencyStale
        self.frontToBackIndex = frontToBackIndex
        self.stackingBasis = stackingBasis
        self.isOnScreen = isOnScreen
        self.alpha = alpha
    }
}

public struct SceneHotSpatialLookup: Hashable, Sendable {
    public let candidates: [SceneHotSpatialCandidate]
    /// Diagnostic count before containment filtering and object deduplication.
    public let examinedCandidates: Int
    /// Hard upper bound for `examinedCandidates`, independent of indexed object count.
    public let examinationLimit: Int
    /// True when more matching indexed candidates existed than the requested result limit.
    public let didTruncateCandidates: Bool
    /// True when a visited index bucket had discarded lower-ranked candidates at build time.
    public let didDropCandidates: Bool

    /// False means the result is deliberately partial and must not be treated as exhaustive.
    public var isComplete: Bool {
        !didTruncateCandidates && !didDropCandidates
    }
}

/// Immutable, actor-independent spatial index. A caller can retain this value and run
/// pointer hit tests without awaiting the memory reducer.
public struct SceneSpatialSnapshot: Sendable {
    private struct BucketKey: Hashable, Sendable {
        let coordinateSpace: SurfaceCoordinateSpace
        let level: UInt8
        let x: Int64
        let y: Int64
    }

    private struct Bucket: Sendable {
        var candidates: [SceneHotSpatialCandidate] = []
        var didDropCandidates = false

        mutating func insert(
            _ candidate: SceneHotSpatialCandidate,
            capacity: Int
        ) {
            let insertionIndex = candidates.firstIndex {
                SceneSpatialSnapshot.precedes(candidate, $0)
            } ?? candidates.endIndex

            guard insertionIndex < capacity else {
                didDropCandidates = true
                return
            }
            candidates.insert(candidate, at: insertionIndex)
            if candidates.count > capacity {
                candidates.removeLast()
                didDropCandidates = true
            }
        }
    }

    public let revision: UInt64
    public let indexedObjects: Int

    /// The synchronous query budget is fixed at 17 buckets times 32 candidates.
    public static var maximumExaminedCandidates: Int {
        (resolutionLevelCount + 1) * bucketCandidateCapacity
    }

    private let cellSpan: Double
    private let buckets: [BucketKey: Bucket]

    private static let resolutionLevelCount = 16
    private static let bucketCandidateCapacity = 32
    private static let maximumCellsPerRegion = 4
    private static let universalLevel = UInt8(resolutionLevelCount)

    init(
        revision: UInt64,
        candidates: [SceneHotSpatialCandidate],
        cellSpan: Double = 128
    ) {
        precondition(cellSpan.isFinite && cellSpan > 0)
        self.revision = revision
        self.indexedObjects = Set(candidates.map(\.sourceObject)).count
        self.cellSpan = cellSpan

        var buckets: [BucketKey: Bucket] = [:]
        for candidate in candidates {
            let keys = Self.bucketKeys(
                for: candidate.region,
                baseSpan: cellSpan
            )
            for key in keys {
                buckets[key, default: Bucket()].insert(
                    candidate,
                    capacity: Self.bucketCandidateCapacity
                )
            }
        }
        self.buckets = buckets
    }

    private static func bucketKeys(
        for region: SurfaceRegion,
        baseSpan: Double
    ) -> [BucketKey] {
        let rect = region.rect
        let maximumX = rect.origin.x + rect.size.width
        let maximumY = rect.origin.y + rect.size.height
        guard maximumX.isFinite, maximumY.isFinite else {
            return [universalKey(for: region.coordinateSpace)]
        }

        var span = baseSpan
        for level in 0 ..< resolutionLevelCount {
            let minimumCellX = cell(rect.origin.x, span: span)
            let maximumCellX = cell(maximumX, span: span)
            let minimumCellY = cell(rect.origin.y, span: span)
            let maximumCellY = cell(maximumY, span: span)
            let columnDelta = maximumCellX.subtractingReportingOverflow(minimumCellX)
            let rowDelta = maximumCellY.subtractingReportingOverflow(minimumCellY)

            if !columnDelta.overflow, !rowDelta.overflow,
               columnDelta.partialValue >= 0, rowDelta.partialValue >= 0,
               columnDelta.partialValue < Int64(maximumCellsPerRegion),
               rowDelta.partialValue < Int64(maximumCellsPerRegion)
            {
                let columnCount = Int(columnDelta.partialValue + 1)
                let rowCount = Int(rowDelta.partialValue + 1)
                if columnCount <= maximumCellsPerRegion / rowCount {
                    var keys: [BucketKey] = []
                    keys.reserveCapacity(columnCount * rowCount)
                    for x in minimumCellX ... maximumCellX {
                        for y in minimumCellY ... maximumCellY {
                            keys.append(
                                BucketKey(
                                    coordinateSpace: region.coordinateSpace,
                                    level: UInt8(level),
                                    x: x,
                                    y: y
                                )
                            )
                        }
                    }
                    return keys
                }
            }
            span *= 2
        }
        return [universalKey(for: region.coordinateSpace)]
    }

    private static func universalKey(
        for coordinateSpace: SurfaceCoordinateSpace
    ) -> BucketKey {
        BucketKey(
            coordinateSpace: coordinateSpace,
            level: universalLevel,
            x: 0,
            y: 0
        )
    }

    static var empty: SceneSpatialSnapshot {
        SceneSpatialSnapshot(revision: 0, candidates: [])
    }

    public func lookup(
        at point: ScenePoint,
        in coordinateSpace: SurfaceCoordinateSpace,
        limit requestedLimit: Int = 8
    ) -> SceneHotSpatialLookup {
        var seen = Set<SourceObjectKey>()
        let limit = min(max(requestedLimit, 1), 64)
        var matches: [SceneHotSpatialCandidate] = []
        var examinedCandidates = 0
        var didDropCandidates = false
        var span = cellSpan

        for level in 0 ..< Self.resolutionLevelCount {
            let key = BucketKey(
                coordinateSpace: coordinateSpace,
                level: UInt8(level),
                x: Self.cell(point.x, span: span),
                y: Self.cell(point.y, span: span)
            )
            if let bucket = buckets[key] {
                didDropCandidates = didDropCandidates || bucket.didDropCandidates
                examinedCandidates += bucket.candidates.count
                for candidate in bucket.candidates
                    where Self.contains(candidate.region.rect, point: point)
                {
                    guard seen.insert(candidate.sourceObject).inserted else { continue }
                    matches.append(candidate)
                }
            }
            span *= 2
        }

        if let bucket = buckets[Self.universalKey(for: coordinateSpace)] {
            didDropCandidates = didDropCandidates || bucket.didDropCandidates
            examinedCandidates += bucket.candidates.count
            for candidate in bucket.candidates
                where Self.contains(candidate.region.rect, point: point)
            {
                guard seen.insert(candidate.sourceObject).inserted else { continue }
                matches.append(candidate)
            }
        }

        matches.sort(by: Self.precedes)
        let didTruncateCandidates = matches.count > limit
        if matches.count > limit {
            matches.removeSubrange(limit...)
        }
        return SceneHotSpatialLookup(
            candidates: matches,
            examinedCandidates: examinedCandidates,
            examinationLimit: Self.maximumExaminedCandidates,
            didTruncateCandidates: didTruncateCandidates,
            didDropCandidates: didDropCandidates
        )
    }

    private static func cell(_ value: Double, span: Double) -> Int64 {
        let divided = (value / span).rounded(.down)
        if divided >= Double(Int64.max) { return Int64.max }
        if divided <= Double(Int64.min) { return Int64.min }
        return Int64(divided)
    }

    private static func contains(_ rect: SceneRect, point: ScenePoint) -> Bool {
        point.x >= rect.origin.x &&
            point.y >= rect.origin.y &&
            point.x <= rect.origin.x + rect.size.width &&
            point.y <= rect.origin.y + rect.size.height
    }

    private static func precedes(
        _ lhs: SceneHotSpatialCandidate,
        _ rhs: SceneHotSpatialCandidate
    ) -> Bool {
        if lhs.isHistorical != rhs.isHistorical { return !lhs.isHistorical }
        if lhs.isDependencyStale != rhs.isDependencyStale {
            return !lhs.isDependencyStale
        }
        switch (lhs.frontToBackIndex, rhs.frontToBackIndex) {
        case let (lhsIndex?, rhsIndex?) where lhsIndex != rhsIndex:
            return lhsIndex < rhsIndex
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        let areaComparison = compareArea(lhs.region.rect, rhs.region.rect)
        if areaComparison != .orderedSame {
            return areaComparison == .orderedAscending
        }
        return Self.objectKey(lhs.sourceObject) < Self.objectKey(rhs.sourceObject)
    }

    /// Compares positive finite rectangle areas without overflowing their products.
    static func compareArea(_ lhs: SceneRect, _ rhs: SceneRect) -> ComparisonResult {
        let lhsRank = areaRank(lhs)
        let rhsRank = areaRank(rhs)
        if lhsRank.exponent != rhsRank.exponent {
            return lhsRank.exponent < rhsRank.exponent ? .orderedAscending : .orderedDescending
        }
        if lhsRank.significand != rhsRank.significand {
            return lhsRank.significand < rhsRank.significand ?
                .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func areaRank(_ rect: SceneRect) -> (
        exponent: Int,
        significand: Double
    ) {
        var exponent = rect.size.width.exponent + rect.size.height.exponent
        var significand = rect.size.width.significand * rect.size.height.significand
        if significand >= 2 {
            exponent += 1
            significand /= 2
        }
        return (exponent, significand)
    }

    private static func objectKey(_ key: SourceObjectKey) -> String {
        [
            key.sourceEpoch.source.device.description,
            key.sourceEpoch.source.source.description,
            key.sourceEpoch.epochID.uuidString,
            key.objectID.description,
        ].joined(separator: ":")
    }
}
