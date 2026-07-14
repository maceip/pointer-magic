import Dispatch
import Foundation
import PointerSceneContracts

/// Identifies which non-authoritative memory layer produced a query result.
/// Neither case is a live hit test and neither can authorize an interaction.
public enum SceneMemoryQueryProvenance: Hashable, Sendable {
    case immutableSpatialSnapshot(revision: UInt64)
    case memoryStoreHydration(spatialSnapshotRevision: UInt64)
}

/// A compact presentation and reuse summary for a query result. It is not action
/// authority or a trust decision. Hydrated fields retain their individual
/// `SceneFieldFreshness`; this is the least-current aggregate state.
public enum SceneMemoryQueryState: String, Hashable, Sendable {
    case immediateCachedGeometry
    case verifiedCurrent
    case provisional
    case stale
    case historical
    case expired
    case unknown
}

/// Cache reads deliberately cannot mint an action capability. An action adapter must
/// perform a fresh platform hit test and carry its own short-lived authorization.
public enum SceneMemoryActionRequirement: String, Hashable, Sendable {
    case freshLiveAnchorRequired
}

public enum SceneMemoryReusePolicyError: Error, Equatable, Sendable {
    case invalidWindow
}

/// Receiver-time reuse bounds. `preferredAgeNs` is the normal cache window; values
/// beyond it may be used only as stale first paint until `staleFallbackAgeNs`.
public struct SceneMemoryReuseWindow: Hashable, Sendable {
    public let preferredAgeNs: UInt64
    public let staleFallbackAgeNs: UInt64

    public init(preferredAgeNs: UInt64, staleFallbackAgeNs: UInt64) throws {
        guard preferredAgeNs <= staleFallbackAgeNs else {
            throw SceneMemoryReusePolicyError.invalidWindow
        }
        self.preferredAgeNs = preferredAgeNs
        self.staleFallbackAgeNs = staleFallbackAgeNs
    }
}

public enum SceneMemoryFieldReuseState: String, Hashable, Sendable {
    case preferred
    case staleFallback
    case expired
}

/// Query-side policy, intentionally separate from producers and the authoritative
/// reducer. Exact field policy wins; otherwise the strictest applicable evidence
/// policy wins, then the default window applies.
public struct SceneMemoryReusePolicy: Hashable, Sendable {
    public let defaultWindow: SceneMemoryReuseWindow
    public let fieldWindows: [SceneFieldKey: SceneMemoryReuseWindow]
    public let evidenceWindows: [SceneEvidenceKind: SceneMemoryReuseWindow]

    public init(
        defaultWindow: SceneMemoryReuseWindow,
        fieldWindows: [SceneFieldKey: SceneMemoryReuseWindow] = [:],
        evidenceWindows: [SceneEvidenceKind: SceneMemoryReuseWindow] = [:]
    ) {
        self.defaultWindow = defaultWindow
        self.fieldWindows = fieldWindows
        self.evidenceWindows = evidenceWindows
    }

    public static var `default`: SceneMemoryReusePolicy {
        // Unknown fields are deliberately conservative. Integrators should inject
        // explicit longer windows for stable identity and role metadata.
        SceneMemoryReusePolicy(
            defaultWindow: try! SceneMemoryReuseWindow(
                preferredAgeNs: 2_000_000_000,
                staleFallbackAgeNs: 30_000_000_000
            ),
            fieldWindows: [
                try! SceneFieldKey("geometry.bounds"): try! SceneMemoryReuseWindow(
                    preferredAgeNs: 100_000_000,
                    staleFallbackAgeNs: 14_400_000_000_000
                ),
                try! SceneFieldKey("accessibility.role"): try! SceneMemoryReuseWindow(
                    preferredAgeNs: 3_600_000_000_000,
                    staleFallbackAgeNs: 86_400_000_000_000
                ),
                try! SceneFieldKey("accessibility.identifier"): try! SceneMemoryReuseWindow(
                    preferredAgeNs: 3_600_000_000_000,
                    staleFallbackAgeNs: 86_400_000_000_000
                ),
                try! SceneFieldKey("content.label"): try! SceneMemoryReuseWindow(
                    preferredAgeNs: 300_000_000_000,
                    staleFallbackAgeNs: 14_400_000_000_000
                ),
                try! SceneFieldKey("accessibility.label"): try! SceneMemoryReuseWindow(
                    preferredAgeNs: 300_000_000_000,
                    staleFallbackAgeNs: 14_400_000_000_000
                ),
            ]
        )
    }

    func window(for field: SceneFieldLookup) -> SceneMemoryReuseWindow {
        window(
            for: field.field,
            evidenceKinds: Set(field.evidence.map(\.kind))
        )
    }

    func window(
        for field: SceneFieldKey,
        evidenceKinds: Set<SceneEvidenceKind>
    ) -> SceneMemoryReuseWindow {
        if let exact = fieldWindows[field] { return exact }
        let evidence = evidenceKinds.compactMap { evidenceWindows[$0] }
        return evidence.min { lhs, rhs in
            if lhs.staleFallbackAgeNs != rhs.staleFallbackAgeNs {
                return lhs.staleFallbackAgeNs < rhs.staleFallbackAgeNs
            }
            return lhs.preferredAgeNs < rhs.preferredAgeNs
        } ?? defaultWindow
    }
}

public struct SceneMemoryProbeCandidate: Hashable, Sendable {
    public let spatial: SceneHotSpatialCandidate
    public let state: SceneMemoryQueryState

    init(
        spatial: SceneHotSpatialCandidate,
        state: SceneMemoryQueryState? = nil
    ) {
        self.spatial = spatial
        let defaultState: SceneMemoryQueryState
        if spatial.isHistorical {
            defaultState = .historical
        } else if spatial.isDependencyStale {
            defaultState = .stale
        } else {
            defaultState = .immediateCachedGeometry
        }
        self.state = state ?? defaultState
    }
}

/// Immediate bounded result from the immutable spatial mirror. This value is safe to
/// obtain on a pointer hot path: it does not await the reducer or perform I/O.
public struct SceneMemoryProbe: Hashable, Sendable {
    public let point: ScenePoint
    public let coordinateSpace: SurfaceCoordinateSpace
    public let provenance: SceneMemoryQueryProvenance
    public let actionRequirement: SceneMemoryActionRequirement
    public let candidates: [SceneMemoryProbeCandidate]
    /// Diagnostic count before containment filtering and object deduplication.
    public let examinedCandidates: Int
    /// True when the result limit omitted otherwise reusable spatial candidates.
    public let didTruncateCandidates: Bool
    /// True when a visited bounded index bucket had discarded lower-ranked candidates.
    public let didDropCandidates: Bool
    public let omittedExpiredGeometryCandidates: Int

    /// False means this cache answer is intentionally partial, not an exhaustive hit list.
    public var isComplete: Bool {
        !didTruncateCandidates && !didDropCandidates &&
            omittedExpiredGeometryCandidates == 0
    }

    public var spatialSnapshotRevision: UInt64 {
        switch provenance {
        case let .immutableSpatialSnapshot(revision): revision
        case let .memoryStoreHydration(revision): revision
        }
    }

    /// Intentionally constant. A cached probe is context, never action authority.
    public var authorizesSideEffects: Bool { false }
}

public struct SceneMemoryHydratedCandidate: Hashable, Sendable {
    public let cached: SceneMemoryProbeCandidate
    public let object: SceneObjectLookup?
    public let fields: [SceneMemoryHydratedField]
    public let omittedExpiredFields: [SceneFieldKey]
    public let state: SceneMemoryQueryState

    init(
        cached: SceneMemoryProbeCandidate,
        object: SceneObjectLookup?,
        fields: [SceneMemoryHydratedField],
        omittedExpiredFields: [SceneFieldKey]
    ) {
        self.cached = cached
        self.object = object
        self.fields = fields
        self.omittedExpiredFields = omittedExpiredFields
        self.state = Self.aggregateState(
            cached: cached,
            object: object,
            fields: fields,
            omittedExpiredFields: omittedExpiredFields
        )
    }

    private static func aggregateState(
        cached: SceneMemoryProbeCandidate,
        object: SceneObjectLookup?,
        fields: [SceneMemoryHydratedField],
        omittedExpiredFields: [SceneFieldKey]
    ) -> SceneMemoryQueryState {
        guard object != nil else {
            return cached.state == .historical ? .historical : .unknown
        }
        let freshness = Set(fields.map(\.lookup.freshness))
        if freshness.contains(.historical) || cached.state == .historical {
            return .historical
        }
        if freshness.contains(.stale) || cached.state == .stale { return .stale }
        if freshness.contains(.provisional) { return .provisional }
        if freshness.contains(.unknown) { return .unknown }
        if !freshness.isEmpty { return .verifiedCurrent }
        if !omittedExpiredFields.isEmpty { return .expired }
        return cached.state
    }
}

public struct SceneMemoryHydratedField: Hashable, Sendable {
    public let lookup: SceneFieldLookup
    public let reuse: SceneMemoryFieldReuseState
}

/// Asynchronously hydrated field state for a prior synchronous probe. Geometry stays
/// tied to the original immutable snapshot so callers can detect a newer probe rather
/// than silently mixing coordinate-space revisions.
public struct SceneMemoryHydratedQuery: Hashable, Sendable {
    public let probe: SceneMemoryProbe
    public let provenance: SceneMemoryQueryProvenance
    public let actionRequirement: SceneMemoryActionRequirement
    public let requestedFields: [SceneFieldKey]
    public let didTruncateRequestedFields: Bool
    public let candidates: [SceneMemoryHydratedCandidate]

    /// Intentionally constant. Even coverage-verified memory needs a fresh live anchor
    /// before an action can be resolved or dispatched.
    public var authorizesSideEffects: Bool { false }
}

private final class PublishedSceneSpatialSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: SceneSpatialSnapshot = .empty
    private var publicationCount: UInt64 = 0

    func load() -> SceneSpatialSnapshot {
        lock.lock()
        let result = snapshot
        lock.unlock()
        return result
    }

    func count() -> UInt64 {
        lock.lock()
        let result = publicationCount
        lock.unlock()
        return result
    }

    @discardableResult
    func publishIfNewer(_ candidate: SceneSpatialSnapshot) -> Bool {
        lock.lock()
        guard candidate.revision > snapshot.revision else {
            lock.unlock()
            return false
        }
        // Keep the displaced copy alive until after unlocking. Its bucket dictionary
        // may be large, and the final ARC release must never extend the reader lock.
        let displaced = snapshot
        snapshot = candidate
        if publicationCount < UInt64.max {
            publicationCount += 1
        }
        lock.unlock()
        withExtendedLifetime(displaced) {}
        return true
    }
}

/// Source-neutral ingestion facade plus an immutable, synchronous spatial read mirror.
/// The actor store remains the sole authorization and reduction authority.
public final class SceneMemorySnapshotMirror: SceneEventSink, @unchecked Sendable {
    public static let maximumHydratedFields = 64

    public let store: SceneMemoryStore
    private let published = PublishedSceneSpatialSnapshot()
    private let reusePolicy: SceneMemoryReusePolicy
    private let receiverNow: @Sendable () -> UInt64

    public init(
        store: SceneMemoryStore,
        reusePolicy: SceneMemoryReusePolicy = .default,
        receiverMonotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.store = store
        self.reusePolicy = reusePolicy
        self.receiverNow = receiverMonotonicNow
    }

    public func ingest(
        _ batch: SceneEventBatch,
        through source: SceneSourceHandle
    ) async -> IngestReceipt {
        let receipt = await store.ingest(batch, through: source)
        guard receipt.status != .rejected else { return receipt }
        let latest = await store.spatialSnapshot()
        published.publishIfNewer(latest)
        return receipt
    }

    /// Publishes reducer-side changes that do not arrive through `ingest`, such as
    /// source registration, closure, or a future deterministic restore operation.
    @discardableResult
    public func synchronizeSnapshot() async -> Bool {
        let latest = await store.spatialSnapshot()
        return published.publishIfNewer(latest)
    }

    public var publishedSnapshotRevision: UInt64 {
        published.load().revision
    }

    /// Diagnostic only; tests and metrics can use it to verify replay idempotence.
    public var snapshotPublicationCount: UInt64 {
        published.count()
    }

    public func probe(
        at point: ScenePoint,
        in coordinateSpace: SurfaceCoordinateSpace,
        limit: Int = 8
    ) -> SceneMemoryProbe {
        // Copy the immutable value under the lock, then do bounded index work after
        // releasing it so readers never serialize on hit testing.
        let snapshot = published.load()
        let limit = min(max(limit, 1), 64)
        let lookup = snapshot.lookup(
            at: point,
            in: coordinateSpace,
            limit: 64
        )
        let now = receiverNow()
        var omitted = 0
        var didTruncateCandidates = lookup.didTruncateCandidates
        var candidates: [SceneMemoryProbeCandidate] = []
        for spatial in lookup.candidates {
            switch reuseState(for: spatial, now: now) {
            case .preferred:
                if candidates.count < limit {
                    candidates.append(SceneMemoryProbeCandidate(spatial: spatial))
                } else {
                    didTruncateCandidates = true
                }
            case .staleFallback:
                if candidates.count < limit {
                    candidates.append(
                        SceneMemoryProbeCandidate(
                            spatial: spatial,
                            state: spatial.isHistorical ? .historical : .stale
                        )
                    )
                } else {
                    didTruncateCandidates = true
                }
            case .expired:
                omitted += 1
            }
        }
        return SceneMemoryProbe(
            point: point,
            coordinateSpace: coordinateSpace,
            provenance: .immutableSpatialSnapshot(revision: snapshot.revision),
            actionRequirement: .freshLiveAnchorRequired,
            candidates: candidates,
            examinedCandidates: lookup.examinedCandidates,
            didTruncateCandidates: didTruncateCandidates,
            didDropCandidates: lookup.didDropCandidates,
            omittedExpiredGeometryCandidates: omitted
        )
    }

    /// Hydrates a prior immediate probe in one actor turn. The requested field list is
    /// deterministically bounded; no disk, network, AppKit, or live platform query is
    /// performed here.
    public func hydrate(
        _ probe: SceneMemoryProbe,
        fields requestedFields: [SceneFieldKey]
    ) async -> SceneMemoryHydratedQuery {
        let fields = Array(requestedFields.prefix(Self.maximumHydratedFields))
        let keys = probe.candidates.map { $0.spatial.sourceObject }
        let lookups = await store.lookup(objects: keys, fields: fields)
        let byObject = Dictionary(
            uniqueKeysWithValues: lookups.map { ($0.sourceObject, $0) }
        )
        let now = receiverNow()
        let candidates = probe.candidates.map { cached in
            let current = byObject[cached.spatial.sourceObject]
            let hydrated = current?.canonicalID == cached.spatial.canonicalID
                ? current
                : nil
            let reused = applyReusePolicy(to: hydrated, now: now)
            return SceneMemoryHydratedCandidate(
                cached: cached,
                object: reused.object,
                fields: reused.fields,
                omittedExpiredFields: reused.omittedExpiredFields
            )
        }
        return SceneMemoryHydratedQuery(
            probe: probe,
            provenance: .memoryStoreHydration(
                spatialSnapshotRevision: probe.spatialSnapshotRevision
            ),
            actionRequirement: .freshLiveAnchorRequired,
            requestedFields: fields,
            didTruncateRequestedFields: requestedFields.count > fields.count,
            candidates: candidates
        )
    }

    private func applyReusePolicy(
        to object: SceneObjectLookup?,
        now: UInt64
    ) -> (
        object: SceneObjectLookup?,
        fields: [SceneMemoryHydratedField],
        omittedExpiredFields: [SceneFieldKey]
    ) {
        guard let object else { return (nil, [], []) }
        var retained: [SceneMemoryHydratedField] = []
        var omitted: [SceneFieldKey] = []
        for field in object.fields {
            let state = reuseState(for: field, now: now)
            switch state {
            case .preferred:
                retained.append(SceneMemoryHydratedField(lookup: field, reuse: state))
            case .staleFallback:
                let stale = SceneFieldLookup(
                    field: field.field,
                    value: field.value,
                    knowledge: field.knowledge,
                    confidence: field.confidence,
                    sensitivity: field.sensitivity,
                    evidence: field.evidence,
                    sourceRevision: field.sourceRevision,
                    observedAtSourceMonotonicNs: field.observedAtSourceMonotonicNs,
                    receivedAtReceiverMonotonicNs: field.receivedAtReceiverMonotonicNs,
                    freshness: field.freshness == .historical ? .historical : .stale
                )
                retained.append(SceneMemoryHydratedField(lookup: stale, reuse: state))
            case .expired:
                omitted.append(field.field)
            }
        }
        let filtered = SceneObjectLookup(
            canonicalID: object.canonicalID,
            sourceObject: object.sourceObject,
            parent: object.parent,
            matchedRegion: object.matchedRegion,
            fields: retained.map(\.lookup)
        )
        return (filtered, retained, omitted.sorted())
    }

    private func reuseState(
        for field: SceneFieldLookup,
        now: UInt64
    ) -> SceneMemoryFieldReuseState {
        guard let received = field.receivedAtReceiverMonotonicNs else { return .expired }
        let age = now >= received ? now - received : 0
        let window = reusePolicy.window(for: field)
        if age <= window.preferredAgeNs { return .preferred }
        if age <= window.staleFallbackAgeNs { return .staleFallback }
        return .expired
    }

    private func reuseState(
        for candidate: SceneHotSpatialCandidate,
        now: UInt64
    ) -> SceneMemoryFieldReuseState {
        let age = now >= candidate.receivedAtReceiverMonotonicNs
            ? now - candidate.receivedAtReceiverMonotonicNs
            : 0
        let window = reusePolicy.window(
            for: candidate.geometryField,
            evidenceKinds: candidate.evidenceKinds
        )
        if age <= window.preferredAgeNs { return .preferred }
        if age <= window.staleFallbackAgeNs { return .staleFallback }
        return .expired
    }
}
