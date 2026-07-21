import Dispatch
import Foundation
import PointerSceneContracts

private struct RegistrationRecord: Sendable {
    let authorization: SceneSourceAuthorization

    var manifest: SceneSourceManifest { authorization.manifest }
    var grant: SceneSourceGrant { authorization.grant }
    var handle: SceneSourceHandle { authorization.handle }
}

private struct InvalidationMarker: Sendable {
    let revision: SourceRevision
    let reason: SceneInvalidationReason
    let receivedAtReceiverMonotonicNs: UInt64
}

private struct StoredField: Sendable {
    let field: SceneFieldKey
    var value: SceneFieldValue?
    let knowledge: SceneClaimKnowledge
    let confidence: Double
    let sensitivity: SceneDataSensitivity
    let evidence: [SceneEvidence]
    let dependencies: [SceneClaimDependency]
    let revision: SourceRevision
    let observedAtSourceMonotonicNs: UInt64
    let receivedAtReceiverMonotonicNs: UInt64
    var invalidation: InvalidationMarker?
}

private struct StoredObject: Sendable {
    let canonicalID: CanonicalSceneObjectID
    let sourceObject: SourceObjectKey
    var parent: SourceObjectKey?
    var fields: [SceneFieldKey: StoredField]
    var fieldTombstones: [SceneFieldKey: InvalidationMarker]
    var objectTombstone: InvalidationMarker?
    var lastMutationOrdinal: UInt64
}

private struct StoredFieldNode: Hashable, Sendable {
    let object: SourceObjectKey
    let field: SceneFieldKey
}

private struct PrivacyObjectFieldKey: Hashable, Sendable {
    let objectID: SourceObjectID
    let field: SceneFieldKey
}

private struct DeviceProcessKey: Hashable, Sendable {
    let device: DevicePrincipalID
    let processID: Int64
}

private let maximumDependencyTraversalNodes = 256
private let maximumDependencyTraversalDepth = 32
private let geometryBoundsField = try! SceneFieldKey("geometry.bounds")
private let applicationPIDField = try! SceneFieldKey("application.pid")
private let windowFrontToBackIndexField = try! SceneFieldKey("window.frontToBackIndex")
private let windowIsOnScreenField = try! SceneFieldKey("window.isOnScreen")
private let windowAlphaField = try! SceneFieldKey("window.alpha")

private struct ReplayEntry: Sendable {
    let envelope: SceneEventEnvelope
    let acceptedOrdinal: UInt64
    let estimatedBytes: Int
}

private struct CoverageRecord: Sendable {
    let sourceEpoch: SceneSourceEpoch
    let streamID: CoverageStreamID
    var scope: SceneCoverageScope
    var lastContinuitySequence: UInt64
    var receivedAtReceiverMonotonicNs: UInt64
    var expiresAtReceiverMonotonicNs: UInt64
    var state: CoverageLeaseState
    var guarantee: CoverageGuarantee
    var coveredFields: Set<SceneFieldKey>
    var coveredEvidenceKinds: Set<SceneEvidenceKind>
    var maximumSilenceNs: UInt64
    var baselineSourceSequence: UInt64?
    var awaitingBaseline: Bool
    var lastMutationOrdinal: UInt64
}

private struct SourceProjection: Sendable {
    var lastAcceptedSequence: UInt64 = 0
    var lastCheckpointSequence: UInt64?
    var checkpointRequiredAfterSequence: UInt64?
    var replayLedger: [UInt64: ReplayEntry] = [:]
    var objects: [SourceObjectID: StoredObject] = [:]
    var retiredObjectIDs: [SourceObjectID: InvalidationMarker] = [:]
    var coverage: [CoverageStreamID: CoverageRecord] = [:]
    /// Any privacy-sensitive fact at or after a revision makes a projection-wide
    /// dependency on that earlier revision unsafe.
    var privacyRevisionWideFloor: UInt64?
    /// Fail-closed compaction target when scoped floor storage reaches its cap.
    var privacyProjectionFloor: UInt64?
    var privacyFieldFloors: [SceneFieldKey: UInt64] = [:]
    var privacyObjectFloors: [SourceObjectID: UInt64] = [:]
    var privacyObjectFieldFloors: [PrivacyObjectFieldKey: UInt64] = [:]
}

private struct MemoryState: Sendable {
    var registrationsByHandle: [SceneSourceHandleID: RegistrationRecord] = [:]
    var activeEpochBySource: [SceneSourceIdentity: SceneSourceEpoch] = [:]
    var retiredEpochs: Set<SceneSourceEpoch> = []
    var registrationLocked = false
    var projections: [SceneSourceEpoch: SourceProjection] = [:]
    var spatialSnapshot: SceneSpatialSnapshot = .empty
    var spatialSnapshotRevision: UInt64 = 0
    /// A coverage event can stale only revision-wide dependencies. This bounded
    /// receiver-derived index avoids rebuilding on ordinary coverage heartbeats.
    var spatialRevisionWideDependencyFloor: [SceneSourceEpoch: UInt64] = [:]
    var nextMutationOrdinal: UInt64 = 1

    mutating func takeOrdinal() -> UInt64 {
        let result = nextMutationOrdinal
        if nextMutationOrdinal < UInt64.max {
            nextMutationOrdinal += 1
        }
        return result
    }
}

private struct AcceptedEvent: Sendable {
    let envelope: SceneEventEnvelope
    let gapBefore: SourceSequenceGap?
}

private enum ReplayPreflight {
    case accepted(events: [AcceptedEvent], replays: [SourceRevision], gaps: [SourceSequenceGap])
    case rejected(IngestRejectionCode)
}

/// Actor-owned, source-neutral scene memory. It is both the receiver-side source
/// registry and the only ingestion reducer; producers never receive a mutable store.
/// State is process-local and is not persisted or restored across a relaunch.
/// Privacy invalidation or nonordinary reclassification purges cached and replayed
/// values that might contain content from an earlier ordinary claim.
public actor SceneMemoryStore: SceneEventSink {
    public let sessionID: SceneSessionID

    private let limits: SceneMemoryLimits
    private let receiverNow: @Sendable () -> UInt64
    private var state = MemoryState()

    public init(
        sessionID: SceneSessionID = SceneSessionID(),
        limits: SceneMemoryLimits = .default,
        receiverMonotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.sessionID = sessionID
        self.limits = limits
        self.receiverNow = receiverMonotonicNow
    }

    /// Mints the non-serializable grant and handle after checking the trusted policy
    /// against the producer's declared manifest.
    public func register(
        manifest: SceneSourceManifest,
        authorization: SceneSourceGrantPolicy
    ) throws -> RegisteredSceneSource {
        try manifest.validate()
        guard manifest.sessionID == sessionID else {
            throw SceneSourceRegistrationError.wrongSession
        }
        guard !state.registrationLocked else {
            throw SceneSourceRegistrationError.retirementCapacityExhausted
        }
        guard manifest.minimumEventSchemaVersion <= SceneEventEnvelope.currentSchemaVersion,
              manifest.maximumEventSchemaVersion >= SceneEventEnvelope.currentSchemaVersion
        else {
            throw SceneSourceRegistrationError.eventSchemaUnsupported
        }

        let declaredCapabilities = Set(manifest.capabilities)
        if let undeclared = authorization.capabilities
            .subtracting(declaredCapabilities)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first
        {
            throw SceneSourceRegistrationError.capabilityNotDeclared(undeclared)
        }
        if authorization.capabilities.contains(.completeEventCoverage),
           !authorization.capabilities.contains(.coverageReporting)
        {
            throw SceneSourceRegistrationError.completeCoverageCapabilityRequired
        }

        let now = receiverNow()
        if let expiry = authorization.expiresAtReceiverMonotonicNs, expiry <= now {
            throw SceneSourceRegistrationError.expiredGrant
        }
        guard !state.retiredEpochs.contains(manifest.sourceEpoch) else {
            throw SceneSourceRegistrationError.retiredEpoch
        }
        if state.registrationsByHandle.values.contains(where: {
            $0.manifest.sourceEpoch == manifest.sourceEpoch
        }) {
            throw SceneSourceRegistrationError.alreadyRegistered
        }

        let grant = SceneSourceGrant(
            sourceEpoch: manifest.sourceEpoch,
            capabilities: authorization.capabilities,
            eventKinds: authorization.eventKinds,
            evidenceKinds: authorization.evidenceKinds,
            fields: authorization.fields,
            surfaces: authorization.surfaces,
            permittedDependencySources: authorization.permittedDependencySources,
            expiresAtReceiverMonotonicNs: authorization.expiresAtReceiverMonotonicNs
        )
        let handle = SceneSourceHandle(
            sourceEpoch: manifest.sourceEpoch,
            sessionID: manifest.sessionID,
            grantID: grant.id
        )
        let sourceAuthorization = try SceneSourceAuthorization(
            manifest: manifest,
            grant: grant,
            handle: handle,
            receiverNowNs: now
        )

        let replacedEpoch = state.activeEpochBySource[manifest.sourceEpoch.source]
            .flatMap { $0 == manifest.sourceEpoch ? nil : $0 }
        let replacedHandles = state.registrationsByHandle.compactMap { id, record in
            record.manifest.sourceEpoch == replacedEpoch ? id : nil
        }
        let retainedRegistrationCount = state.registrationsByHandle.count -
            replacedHandles.count
        guard retainedRegistrationCount < limits.maximumRegisteredSources else {
            throw SceneSourceRegistrationError.sourceLimitReached
        }

        if let replacedEpoch {
            breakAllCoverage(
                in: replacedEpoch,
                reason: .sourceRestarted,
                receivedAt: now,
                state: &state
            )
            for id in replacedHandles {
                state.registrationsByHandle.removeValue(forKey: id)
            }
            retire(replacedEpoch, state: &state)
        }
        state.registrationsByHandle[handle.id] = RegistrationRecord(
            authorization: sourceAuthorization
        )
        state.activeEpochBySource[manifest.sourceEpoch.source] = manifest.sourceEpoch
        if state.projections[manifest.sourceEpoch] == nil {
            state.projections[manifest.sourceEpoch] = SourceProjection()
        }
        rebuildSpatialIndex(state: &state)
        return RegisteredSceneSource(manifest: manifest, grant: grant, handle: handle)
    }

    /// Ends the receiver-side registration immediately. The epoch cannot be reopened;
    /// a producer restart must register a new epoch.
    @discardableResult
    public func closeSource(
        _ source: SceneSourceHandle,
        reason: CoverageGapReason = .disconnected
    ) -> Bool {
        guard let registration = state.registrationsByHandle[source.id],
              registration.handle == source,
              !state.retiredEpochs.contains(source.sourceEpoch)
        else {
            return false
        }
        let now = receiverNow()
        breakAllCoverage(
            in: source.sourceEpoch,
            reason: reason,
            receivedAt: now,
            state: &state
        )
        state.registrationsByHandle.removeValue(forKey: source.id)
        if state.activeEpochBySource[source.sourceEpoch.source] == source.sourceEpoch {
            state.activeEpochBySource.removeValue(forKey: source.sourceEpoch.source)
        }
        retire(source.sourceEpoch, state: &state)
        rebuildSpatialIndex(state: &state)
        return true
    }

    public func ingest(
        _ batch: SceneEventBatch,
        through source: SceneSourceHandle
    ) async -> IngestReceipt {
        let receivedAt = receiverNow()

        if state.activeEpochBySource[source.sourceEpoch.source].map({
                $0 != source.sourceEpoch
            }) == true
        {
            return receipt(batch: batch, rejection: .staleEpoch)
        }
        guard let registration = state.registrationsByHandle[source.id],
              registration.handle == source,
              source.sessionID == sessionID,
              source.grantID == registration.grant.id,
              source.sourceEpoch == registration.manifest.sourceEpoch,
              batch.sourceEpoch == source.sourceEpoch
        else {
            return receipt(batch: batch, rejection: .unauthorizedSource)
        }
        guard state.activeEpochBySource[source.sourceEpoch.source] == source.sourceEpoch else {
            return receipt(batch: batch, rejection: .staleEpoch)
        }
        if let expiry = registration.grant.expiresAtReceiverMonotonicNs,
           receivedAt >= expiry
        {
            return receipt(batch: batch, rejection: .expiredGrant)
        }
        do {
            try registration.authorization.validate(batch, receiverNowNs: receivedAt)
        } catch let error as SceneContractValidationError {
            return receipt(batch: batch, rejection: rejectionCode(for: error))
        } catch {
            return receipt(batch: batch, rejection: .invalidBatch)
        }

        var transaction = state
        let sourceEpoch = source.sourceEpoch
        let projection = transaction.projections[sourceEpoch] ?? SourceProjection()
        let replay = preflightReplay(batch: batch, projection: projection)
        let acceptedEvents: [AcceptedEvent]
        let identicalReplays: [SourceRevision]
        let gaps: [SourceSequenceGap]
        switch replay {
        case let .accepted(events, replays, sequenceGaps):
            acceptedEvents = events
            identicalReplays = replays
            gaps = sequenceGaps
        case let .rejected(code):
            return receipt(batch: batch, rejection: code)
        }

        if acceptedEvents.isEmpty {
            let acceptedThrough = state.projections[sourceEpoch].flatMap { projection in
                try? SourceRevision(
                    sourceEpoch: sourceEpoch,
                    sequence: projection.lastAcceptedSequence
                )
            }
            return makeReceipt(
                batchID: batch.batchID,
                status: .accepted,
                acceptedThrough: acceptedThrough,
                identicalReplays: identicalReplays,
                gaps: [],
                rejection: nil
            )
        }

        var shouldReevaluatePrivacyDependencies = false
        var shouldPurgePotentiallyDependentReplay = false
        var shouldRebuildSpatialIndex = false
        for accepted in acceptedEvents {
            if let gap = accepted.gapBefore {
                breakAllCoverage(
                    in: sourceEpoch,
                    reason: .sequenceGap,
                    receivedAt: receivedAt,
                    state: &transaction
                )
                requireCheckpoint(
                    in: sourceEpoch,
                    after: gap.missingThrough,
                    state: &transaction
                )
            }
            apply(
                accepted.envelope,
                receivedAt: receivedAt,
                state: &transaction
            )
            if containsNonordinaryClaim(accepted.envelope) {
                // The replay ledger retains complete envelopes. If a producer
                // reclassifies a fact as secure or unknown, an older ordinary
                // envelope for this source may still contain the now-sensitive
                // bytes. Drop that history in the same transaction before the
                // new value-less event becomes observable.
                transaction.projections[sourceEpoch]?
                    .replayLedger.removeAll(keepingCapacity: false)
                shouldPurgePotentiallyDependentReplay = true
            }
            recordReplay(accepted.envelope, state: &transaction)
            switch accepted.envelope.payload {
            case .observation:
                shouldReevaluatePrivacyDependencies =
                    shouldReevaluatePrivacyDependencies ||
                    requiresPrivacyDependencyReevaluation(accepted.envelope)
                shouldRebuildSpatialIndex = true
            case .checkpoint:
                shouldReevaluatePrivacyDependencies = true
                // Projection replacement can make a dependency unresolvable
                // even when its derived object was already budget-evicted.
                shouldPurgePotentiallyDependentReplay = true
                shouldRebuildSpatialIndex = true
            case let .invalidation(invalidation):
                shouldRebuildSpatialIndex = true
                shouldReevaluatePrivacyDependencies =
                    shouldReevaluatePrivacyDependencies ||
                    invalidation.reason == .privacyBoundary
                shouldPurgePotentiallyDependentReplay =
                    shouldPurgePotentiallyDependentReplay ||
                    invalidation.reason == .privacyBoundary
            case .coverage:
                let revision = accepted.envelope.revision
                if let floor = state.spatialRevisionWideDependencyFloor[
                    revision.sourceEpoch
                ], revision.sequence > floor {
                    shouldRebuildSpatialIndex = true
                }
            }
        }
        if shouldReevaluatePrivacyDependencies {
            purgePrivacyDependentValues(state: &transaction)
        }

        guard transaction.projections.values.allSatisfy({
            $0.retiredObjectIDs.count <= limits.maximumRetiredObjectIDsPerSource
        }) else {
            return receipt(batch: batch, rejection: .reducerUnavailable)
        }
        let didEvictObjects = enforceBudgets(state: &transaction)
        if didEvictObjects {
            // Eviction can make an exact dependency unresolvable after the
            // pre-budget privacy pass. Purge derived bytes again before this
            // transaction is published; a stale marker alone is not a privacy
            // boundary.
            purgePrivacyDependentValues(state: &transaction)
            shouldPurgePotentiallyDependentReplay = true
        }
        if shouldPurgePotentiallyDependentReplay {
            purgePotentiallyDependentReplayPayloads(state: &transaction)
        }
        guard estimatedTotalBytes(transaction) <= limits.maximumEstimatedBytes else {
            return receipt(batch: batch, rejection: .reducerUnavailable)
        }
        if shouldRebuildSpatialIndex || didEvictObjects {
            rebuildSpatialIndex(state: &transaction)
        }
        state = transaction

        let acceptedThrough = state.projections[sourceEpoch].flatMap { projection in
            try? SourceRevision(
                sourceEpoch: sourceEpoch,
                sequence: projection.lastAcceptedSequence
            )
        }
        return makeReceipt(
            batchID: batch.batchID,
            status: gaps.isEmpty ? .accepted : .acceptedWithCoverageGap,
            acceptedThrough: acceptedThrough,
            identicalReplays: identicalReplays,
            gaps: gaps,
            rejection: nil
        )
    }

    public func canonicalIdentity(for object: SourceObjectKey) -> CanonicalSceneObjectID? {
        state.projections[object.sourceEpoch]?.objects[object.objectID]?.canonicalID
    }

    public func spatialSnapshot() -> SceneSpatialSnapshot {
        state.spatialSnapshot
    }

    /// Single-object inspection deliberately treats an empty field list as "all
    /// stored fields." It is separate from the multi-object hydration API and is
    /// bounded by this store's configured field budget.
    public func lookup(
        object: SourceObjectKey,
        fields requestedFields: [SceneFieldKey] = []
    ) -> SceneObjectLookup? {
        guard let stored = state.projections[object.sourceEpoch]?.objects[object.objectID] else {
            return nil
        }
        let now = receiverNow()
        return makeObjectLookup(
            stored,
            matchedRegion: nil,
            requestedFields: requestedFields,
            emptyFieldSelection: .all,
            now: now
        )
    }

    /// Consistent bounded hydration for candidates obtained from an immutable spatial
    /// snapshot. At most 64 objects and 64 explicitly requested fields are inspected;
    /// an empty field list means zero fields. Missing or evicted objects are omitted.
    public func lookup(
        objects: [SourceObjectKey],
        fields requestedFields: [SceneFieldKey] = []
    ) -> [SceneObjectLookup] {
        let keys = Array(objects.prefix(64))
        let fields = Array(requestedFields.prefix(64))
        let now = receiverNow()
        return keys.compactMap { key in
            guard let stored = state.projections[key.sourceEpoch]?.objects[key.objectID] else {
                return nil
            }
            return makeObjectLookup(
                stored,
                matchedRegion: nil,
                requestedFields: fields,
                emptyFieldSelection: .none,
                now: now
            )
        }
    }

    /// Exact coordinate-space revision matching is intentional: geometry from an old
    /// display layout is never silently transformed into the current one. Candidate
    /// and explicit field hydration are independently capped at 64; empty fields
    /// means geometry-only candidate metadata, not every stored field.
    public func lookup(
        at point: ScenePoint,
        in coordinateSpace: SurfaceCoordinateSpace,
        fields requestedFields: [SceneFieldKey] = [],
        limit requestedLimit: Int = 8
    ) -> SceneSpatialLookup {
        let limit = min(max(requestedLimit, 1), 64)
        let fields = Array(requestedFields.prefix(64))
        let now = receiverNow()
        let hot = state.spatialSnapshot.lookup(
            at: point,
            in: coordinateSpace,
            limit: limit
        )
        var candidates: [SceneObjectLookup] = []
        candidates.reserveCapacity(hot.candidates.count)
        for candidate in hot.candidates {
            let key = candidate.sourceObject
            guard let object = state.projections[key.sourceEpoch]?.objects[key.objectID]
            else {
                continue
            }
            candidates.append(
                makeObjectLookup(
                    object,
                    matchedRegion: candidate.region,
                    requestedFields: fields,
                    emptyFieldSelection: .none,
                    now: now
                )
            )
        }
        return SceneSpatialLookup(
            coordinateSpace: coordinateSpace,
            point: point,
            candidates: candidates,
            examinedCandidates: hot.examinedCandidates,
            examinationLimit: hot.examinationLimit,
            didTruncateCandidates: hot.didTruncateCandidates,
            didDropCandidates: hot.didDropCandidates
        )
    }

    public func coverageLease(
        sourceEpoch: SceneSourceEpoch,
        streamID: CoverageStreamID
    ) -> CoverageLease? {
        guard let record = state.projections[sourceEpoch]?.coverage[streamID] else {
            return nil
        }
        let exposedState: CoverageLeaseState
        if case .current = record.state,
           receiverNow() >= record.expiresAtReceiverMonotonicNs
        {
            // Freshness already uses receiver time. The diagnostic lease API
            // must agree even when a silent producer never emits the event that
            // would materialize this transition in reducer state.
            exposedState = .broken(.producerPaused)
        } else {
            exposedState = record.state
        }
        return try? CoverageLease(
            sourceEpoch: record.sourceEpoch,
            streamID: record.streamID,
            scope: record.scope,
            lastContinuitySequence: record.lastContinuitySequence,
            receivedAtReceiverMonotonicNs: record.receivedAtReceiverMonotonicNs,
            expiresAtReceiverMonotonicNs: record.expiresAtReceiverMonotonicNs,
            state: exposedState,
            guarantee: record.guarantee,
            coveredFields: record.coveredFields,
            coveredEvidenceKinds: record.coveredEvidenceKinds
        )
    }

    public func statistics() -> SceneMemoryStatistics {
        var objectCount = 0
        var fieldCount = 0
        var replayCount = 0
        var coverageCount = 0
        var privacyFloorCount = 0
        for projection in state.projections.values {
            objectCount += projection.objects.count
            fieldCount += projection.objects.values.reduce(0) { $0 + $1.fields.count }
            replayCount += projection.replayLedger.count
            coverageCount += projection.coverage.count
            privacyFloorCount += privacyRevisionFloorCount(projection)
        }
        return SceneMemoryStatistics(
            registeredSources: state.registrationsByHandle.count,
            sourceProjections: state.projections.count,
            objects: objectCount,
            fields: fieldCount,
            estimatedBytes: estimatedTotalBytes(state),
            replayEntries: replayCount,
            coverageStreams: coverageCount,
            privacyRevisionFloors: privacyFloorCount
        )
    }
}

// MARK: - Registration and authority

private extension SceneMemoryStore {
    func retire(_ epoch: SceneSourceEpoch, state: inout MemoryState) {
        guard !state.retiredEpochs.contains(epoch) else { return }
        guard state.retiredEpochs.count < limits.maximumRetiredSourceEpochs else {
            state.registrationLocked = true
            return
        }
        state.retiredEpochs.insert(epoch)
        if state.retiredEpochs.count >= limits.maximumRetiredSourceEpochs {
            // The retired IDs are the proof that an old epoch can never regain
            // authority. Once that bounded proof set is full, fail closed for all
            // future registrations rather than evicting an epoch and reopening it.
            state.registrationLocked = true
        }
    }

    func rejectionCode(for error: SceneContractValidationError) -> IngestRejectionCode {
        switch error {
        case .expired:
            return .expiredGrant
        case let .unauthorized(field) where field == "event.surfaces":
            return .unauthorizedSurface
        case .unauthorized:
            return .unauthorizedCapability
        case .sourceMismatch:
            return .unauthorizedSource
        case .revisionEquivocation:
            return .sequenceEquivocation
        default:
            return .invalidBatch
        }
    }
}

// MARK: - Replay and reduction

private extension SceneMemoryStore {
    func preflightReplay(
        batch: SceneEventBatch,
        projection: SourceProjection
    ) -> ReplayPreflight {
        var cursor = projection.lastAcceptedSequence
        var accepted: [AcceptedEvent] = []
        var replays: [SourceRevision] = []
        var gaps: [SourceSequenceGap] = []

        for event in batch.events {
            let sequence = event.revision.sequence
            if let existing = projection.replayLedger[sequence] {
                if existing.envelope == event {
                    replays.append(event.revision)
                    continue
                }
                return .rejected(.sequenceEquivocation)
            }
            guard sequence > cursor else {
                // The comparison record was deterministically evicted, so an old
                // sequence cannot be proven identical and is never applied again.
                return .rejected(.invalidBatch)
            }

            var gap: SourceSequenceGap?
            if cursor < UInt64.max, sequence > cursor + 1 {
                gap = try? SourceSequenceGap(
                    sourceEpoch: batch.sourceEpoch,
                    missingFrom: cursor + 1,
                    missingThrough: sequence - 1
                )
                if let gap { gaps.append(gap) }
            }
            accepted.append(AcceptedEvent(envelope: event, gapBefore: gap))
            cursor = sequence
        }
        return .accepted(events: accepted, replays: replays, gaps: gaps)
    }

    func apply(
        _ event: SceneEventEnvelope,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        switch event.payload {
        case let .observation(observation):
            applyObservation(
                observation,
                revision: event.revision,
                receivedAt: receivedAt,
                state: &state
            )
        case let .invalidation(invalidation):
            applyInvalidation(
                invalidation,
                revision: event.revision,
                receivedAt: receivedAt,
                state: &state
            )
        case let .coverage(report):
            applyCoverage(
                report,
                revision: event.revision,
                receivedAt: receivedAt,
                state: &state
            )
        case let .checkpoint(checkpoint):
            applyCheckpoint(
                checkpoint,
                revision: event.revision,
                receivedAt: receivedAt,
                state: &state
            )
        }
        var projection = state.projections[event.revision.sourceEpoch] ?? SourceProjection()
        projection.lastAcceptedSequence = event.revision.sequence
        state.projections[event.revision.sourceEpoch] = projection
    }

    func applyObservation(
        _ observation: SceneObservation,
        revision: SourceRevision,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        var projection = state.projections[revision.sourceEpoch] ?? SourceProjection()
        guard projection.retiredObjectIDs[observation.subject.objectID] == nil else {
            // Source object IDs are incarnations, not reusable slots. A producer must
            // mint a new ID after a destructive tombstone.
            return
        }
        let existing = projection.objects[observation.subject.objectID]
        var object = existing ?? StoredObject(
            canonicalID: CanonicalSceneObjectID(),
            sourceObject: observation.subject,
            parent: observation.parent,
            fields: [:],
            fieldTombstones: [:],
            objectTombstone: nil,
            lastMutationOrdinal: 0
        )
        object.parent = observation.parent
        object.objectTombstone = nil
        for claim in observation.claims {
            object.fieldTombstones.removeValue(forKey: claim.field)
            object.fields[claim.field] = StoredField(
                field: claim.field,
                value: claim.sensitivity == .ordinary ? claim.value : nil,
                knowledge: claim.knowledge,
                confidence: claim.confidence,
                sensitivity: claim.sensitivity,
                evidence: claim.evidence,
                dependencies: claim.dependencies,
                revision: revision,
                observedAtSourceMonotonicNs: observation.observedAtSourceMonotonicNs,
                receivedAtReceiverMonotonicNs: receivedAt,
                invalidation: nil
            )
            if claim.sensitivity != .ordinary {
                recordPrivacyFloor(
                    objectID: observation.subject.objectID,
                    field: claim.field,
                    through: revision.sequence,
                    projection: &projection
                )
            }
        }
        object.lastMutationOrdinal = state.takeOrdinal()
        projection.objects[observation.subject.objectID] = object
        state.projections[revision.sourceEpoch] = projection
    }

    func applyCheckpoint(
        _ checkpoint: SceneCheckpoint,
        revision: SourceRevision,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        var projection = state.projections[revision.sourceEpoch] ?? SourceProjection()
        let priorIdentities = projection.objects.mapValues(\.canonicalID)
        let includedObjectIDs = Set(checkpoint.observations.map { $0.subject.objectID })
        let omissionMarker = InvalidationMarker(
            revision: revision,
            reason: .destroyed,
            receivedAtReceiverMonotonicNs: receivedAt
        )
        for omittedID in projection.objects.keys where !includedObjectIDs.contains(omittedID) {
            projection.retiredObjectIDs[omittedID] =
                projection.retiredObjectIDs[omittedID] ?? omissionMarker
            pruneScopedPrivacyFloors(
                forPermanentlyRetiredObjectID: omittedID,
                projection: &projection
            )
        }
        projection.objects.removeAll(keepingCapacity: true)
        state.projections[revision.sourceEpoch] = projection

        for observation in checkpoint.observations {
            guard state.projections[revision.sourceEpoch]?
                .retiredObjectIDs[observation.subject.objectID] == nil
            else {
                continue
            }
            applyObservation(
                observation,
                revision: revision,
                receivedAt: receivedAt,
                state: &state
            )
            if let priorID = priorIdentities[observation.subject.objectID],
               var current = state.projections[revision.sourceEpoch]?
                   .objects[observation.subject.objectID]
            {
                current = StoredObject(
                    canonicalID: priorID,
                    sourceObject: current.sourceObject,
                    parent: current.parent,
                    fields: current.fields,
                    fieldTombstones: current.fieldTombstones,
                    objectTombstone: current.objectTombstone,
                    lastMutationOrdinal: current.lastMutationOrdinal
                )
                state.projections[revision.sourceEpoch]?
                    .objects[observation.subject.objectID] = current
            }
        }

        guard var completed = state.projections[revision.sourceEpoch] else { return }
        completed.lastCheckpointSequence = revision.sequence
        if let required = completed.checkpointRequiredAfterSequence,
           revision.sequence > required
        {
            completed.checkpointRequiredAfterSequence = nil
        }
        var expiredAwaitingBaseline = false
        for streamID in completed.coverage.keys {
            guard var lease = completed.coverage[streamID], lease.awaitingBaseline,
                  receivedAt >= lease.expiresAtReceiverMonotonicNs
            else {
                continue
            }
            lease.awaitingBaseline = false
            lease.baselineSourceSequence = nil
            lease.state = .broken(.producerPaused)
            lease.receivedAtReceiverMonotonicNs = receivedAt
            lease.expiresAtReceiverMonotonicNs = receivedAt
            lease.lastMutationOrdinal = state.takeOrdinal()
            completed.coverage[streamID] = lease
            expiredAwaitingBaseline = true
        }
        if expiredAwaitingBaseline {
            completed.checkpointRequiredAfterSequence = max(
                completed.checkpointRequiredAfterSequence ?? 0,
                revision.sequence
            )
        }
        if completed.checkpointRequiredAfterSequence == nil {
            for streamID in completed.coverage.keys {
                guard var lease = completed.coverage[streamID], lease.awaitingBaseline else {
                    continue
                }
                lease.awaitingBaseline = false
                lease.baselineSourceSequence = revision.sequence
                lease.state = .current
                lease.lastMutationOrdinal = state.takeOrdinal()
                completed.coverage[streamID] = lease
            }
        }
        state.projections[revision.sourceEpoch] = completed
    }

    func applyInvalidation(
        _ invalidation: SceneInvalidation,
        revision: SourceRevision,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        var projection = state.projections[revision.sourceEpoch] ?? SourceProjection()
        var targetIDs = matchingObjectIDs(
            scope: invalidation.scope,
            projection: projection
        )
        if case let .object(key) = invalidation.scope,
           projection.objects[key.objectID] == nil
        {
            projection.objects[key.objectID] = StoredObject(
                canonicalID: CanonicalSceneObjectID(),
                sourceObject: key,
                parent: nil,
                fields: [:],
                fieldTombstones: [:],
                objectTombstone: nil,
                lastMutationOrdinal: state.takeOrdinal()
            )
            targetIDs.append(key.objectID)
        }

        let marker = InvalidationMarker(
            revision: revision,
            reason: invalidation.reason,
            receivedAtReceiverMonotonicNs: receivedAt
        )
        let destructive = invalidation.reason == .destroyed ||
            invalidation.reason == .privacyBoundary ||
            invalidation.reason == .explicitRetraction

        for objectID in Set(targetIDs) {
            guard var object = projection.objects[objectID] else { continue }
            let fields = invalidation.fields.isEmpty
                ? Array(object.fields.keys)
                : invalidation.fields
            for field in fields {
                object.fieldTombstones[field] = marker
                if var stored = object.fields[field] {
                    stored.invalidation = marker
                    if invalidation.reason == .privacyBoundary {
                        stored.value = nil
                    }
                    object.fields[field] = stored
                }
            }
            if destructive, invalidation.fields.isEmpty {
                object.objectTombstone = marker
                projection.retiredObjectIDs[objectID] = marker
            }
            object.lastMutationOrdinal = state.takeOrdinal()
            projection.objects[objectID] = object
        }
        if invalidation.reason == .privacyBoundary {
            // Exact replay payloads can contain formerly ordinary values. Once the
            // receiver learns that this scope crossed a privacy boundary, preserving
            // those old envelopes would defeat the value purge above.
            projection.replayLedger.removeAll(keepingCapacity: false)
            recordPrivacyBoundary(
                scope: invalidation.scope,
                fields: invalidation.fields,
                affectedObjectIDs: Set(targetIDs),
                through: revision.sequence,
                projection: &projection
            )
        }
        state.projections[revision.sourceEpoch] = projection
    }

    func matchingObjectIDs(
        scope: SceneInvalidationScope,
        projection: SourceProjection
    ) -> [SourceObjectID] {
        switch scope {
        case let .object(key):
            return [key.objectID]
        case let .region(region):
            return projection.objects.values.compactMap { object in
                object.fields.values.contains(where: { field in
                    guard case let .region(candidate) = field.value else { return false }
                    return intersects(candidate, region)
                }) ? object.sourceObject.objectID : nil
            }
        case let .surface(surface):
            return projection.objects.values.compactMap { object in
                object.fields.values.contains(where: { field in
                    guard case let .region(candidate) = field.value else { return false }
                    return candidate.coordinateSpace.surface == surface
                }) ? object.sourceObject.objectID : nil
            }
        case .sourceProjection:
            return Array(projection.objects.keys)
        }
    }

    func recordPrivacyBoundary(
        scope: SceneInvalidationScope,
        fields: [SceneFieldKey],
        affectedObjectIDs: Set<SourceObjectID>,
        through sequence: UInt64,
        projection: inout SourceProjection
    ) {
        projection.privacyRevisionWideFloor = max(
            projection.privacyRevisionWideFloor ?? 0,
            sequence
        )
        switch scope {
        case .sourceProjection where fields.isEmpty:
            promotePrivacyFloorsToProjection(
                through: sequence,
                projection: &projection
            )
        case .sourceProjection:
            for field in fields {
                recordPrivacyFloor(
                    field: field,
                    through: sequence,
                    projection: &projection
                )
            }
        case .region, .surface:
            // Public window metadata is not a persistent spatial history. Even
            // when some current objects match, another matching object may have
            // been budget-evicted. Promote every spatial privacy boundary so an
            // exact old dependency cannot later resurrect private bytes.
            promotePrivacyFloorsToProjection(
                through: sequence,
                projection: &projection
            )
        case .object:
            guard !affectedObjectIDs.isEmpty else {
                // Defensive fail-closed fallback; applyInvalidation normally
                // synthesizes a placeholder for a missing exact object.
                promotePrivacyFloorsToProjection(
                    through: sequence,
                    projection: &projection
                )
                break
            }
            for objectID in affectedObjectIDs {
                if fields.isEmpty {
                    recordPrivacyFloor(
                        objectID: objectID,
                        through: sequence,
                        projection: &projection
                    )
                } else {
                    for field in fields {
                        recordPrivacyFloor(
                            objectID: objectID,
                            field: field,
                            through: sequence,
                            projection: &projection
                        )
                    }
                }
            }
        }
    }

    func recordPrivacyFloor(
        field: SceneFieldKey,
        through sequence: UInt64,
        projection: inout SourceProjection
    ) {
        projection.privacyRevisionWideFloor = max(
            projection.privacyRevisionWideFloor ?? 0,
            sequence
        )
        if let prior = projection.privacyFieldFloors[field] {
            projection.privacyFieldFloors[field] = max(prior, sequence)
            return
        }
        guard reserveScopedPrivacyFloor(through: sequence, projection: &projection) else {
            return
        }
        projection.privacyFieldFloors[field] = sequence
    }

    func recordPrivacyFloor(
        objectID: SourceObjectID,
        through sequence: UInt64,
        projection: inout SourceProjection
    ) {
        projection.privacyRevisionWideFloor = max(
            projection.privacyRevisionWideFloor ?? 0,
            sequence
        )
        if let prior = projection.privacyObjectFloors[objectID] {
            projection.privacyObjectFloors[objectID] = max(prior, sequence)
            return
        }
        guard reserveScopedPrivacyFloor(through: sequence, projection: &projection) else {
            return
        }
        projection.privacyObjectFloors[objectID] = sequence
    }

    func recordPrivacyFloor(
        objectID: SourceObjectID,
        field: SceneFieldKey,
        through sequence: UInt64,
        projection: inout SourceProjection
    ) {
        projection.privacyRevisionWideFloor = max(
            projection.privacyRevisionWideFloor ?? 0,
            sequence
        )
        let key = PrivacyObjectFieldKey(objectID: objectID, field: field)
        if let prior = projection.privacyObjectFieldFloors[key] {
            projection.privacyObjectFieldFloors[key] = max(prior, sequence)
            return
        }
        guard reserveScopedPrivacyFloor(through: sequence, projection: &projection) else {
            return
        }
        projection.privacyObjectFieldFloors[key] = sequence
    }

    func reserveScopedPrivacyFloor(
        through sequence: UInt64,
        projection: inout SourceProjection
    ) -> Bool {
        guard scopedPrivacyRevisionFloorCount(projection) <
            limits.maximumPrivacyRevisionFloorsPerSource
        else {
            promotePrivacyFloorsToProjection(
                through: sequence,
                projection: &projection
            )
            return false
        }
        return true
    }

    func promotePrivacyFloorsToProjection(
        through sequence: UInt64,
        projection: inout SourceProjection
    ) {
        projection.privacyProjectionFloor = max(
            projection.privacyProjectionFloor ?? 0,
            sequence
        )
        projection.privacyFieldFloors.removeAll(keepingCapacity: false)
        projection.privacyObjectFloors.removeAll(keepingCapacity: false)
        projection.privacyObjectFieldFloors.removeAll(keepingCapacity: false)
    }

    func pruneScopedPrivacyFloors(
        forPermanentlyRetiredObjectID objectID: SourceObjectID,
        projection: inout SourceProjection
    ) {
        projection.privacyObjectFloors.removeValue(forKey: objectID)
        let keys = projection.privacyObjectFieldFloors.keys.filter {
            $0.objectID == objectID
        }
        for key in keys {
            projection.privacyObjectFieldFloors.removeValue(forKey: key)
        }
    }

    func applyCoverage(
        _ report: CoverageReport,
        revision: SourceRevision,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        var projection = state.projections[revision.sourceEpoch] ?? SourceProjection()
        if case .started = report.state {
            materializeExpiredCoverage(
                in: &projection,
                receivedAt: receivedAt,
                checkpointRequiredAfter: revision.sequence,
                state: &state
            )
        }
        let prior = projection.coverage[report.streamID]
        let ordinal = state.takeOrdinal()

        switch report.state {
        case let .started(maximumSilenceNs):
            let effectiveSilence = min(maximumSilenceNs, limits.maximumCoverageSilenceNs)
            let usableBaseline: UInt64? = projection.lastCheckpointSequence.flatMap {
                checkpoint -> UInt64? in
                if let required = projection.checkpointRequiredAfterSequence,
                   checkpoint <= required
                {
                    return nil
                }
                return checkpoint
            }
            let awaitingBaseline = report.guarantee == .completeEvents && usableBaseline == nil
            projection.coverage[report.streamID] = CoverageRecord(
                sourceEpoch: revision.sourceEpoch,
                streamID: report.streamID,
                scope: report.scope,
                lastContinuitySequence: report.continuitySequence,
                receivedAtReceiverMonotonicNs: receivedAt,
                expiresAtReceiverMonotonicNs: addingSaturating(
                    receivedAt,
                    effectiveSilence
                ),
                state: awaitingBaseline ? .broken(.unknown) : .current,
                guarantee: report.guarantee,
                coveredFields: Set(report.coveredFields),
                coveredEvidenceKinds: Set(report.coveredEvidenceKinds),
                maximumSilenceNs: effectiveSilence,
                baselineSourceSequence: usableBaseline,
                awaitingBaseline: awaitingBaseline,
                lastMutationOrdinal: ordinal
            )
        case .heartbeat:
            guard var lease = prior,
                  lease.lastContinuitySequence < UInt64.max,
                  report.continuitySequence == lease.lastContinuitySequence + 1,
                  report.scope == lease.scope,
                  report.guarantee == lease.guarantee,
                  Set(report.coveredFields) == lease.coveredFields,
                  Set(report.coveredEvidenceKinds) == lease.coveredEvidenceKinds,
                  receivedAt < lease.expiresAtReceiverMonotonicNs,
                  lease.awaitingBaseline || lease.state == .current
            else {
                let reason: CoverageGapReason
                if let prior, receivedAt >= prior.expiresAtReceiverMonotonicNs {
                    reason = .producerPaused
                } else {
                    reason = .sequenceGap
                }
                projection.coverage[report.streamID] = brokenCoverageRecord(
                    report: report,
                    revision: revision,
                    receivedAt: receivedAt,
                    prior: prior,
                    ordinal: ordinal,
                    reason: reason
                )
                projection.checkpointRequiredAfterSequence = max(
                    projection.checkpointRequiredAfterSequence ?? 0,
                    revision.sequence
                )
                state.projections[revision.sourceEpoch] = projection
                enforceCoverageLimit(
                    in: revision.sourceEpoch,
                    after: revision.sequence,
                    receivedAt: receivedAt,
                    state: &state
                )
                return
            }
            lease.lastContinuitySequence = report.continuitySequence
            lease.receivedAtReceiverMonotonicNs = receivedAt
            lease.expiresAtReceiverMonotonicNs = addingSaturating(
                receivedAt,
                lease.maximumSilenceNs
            )
            lease.lastMutationOrdinal = ordinal
            projection.coverage[report.streamID] = lease
        case let .gap(reason):
            projection.coverage[report.streamID] = brokenCoverageRecord(
                report: report,
                revision: revision,
                receivedAt: receivedAt,
                prior: prior,
                ordinal: ordinal,
                reason: reason
            )
            projection.checkpointRequiredAfterSequence = max(
                projection.checkpointRequiredAfterSequence ?? 0,
                revision.sequence
            )
        case let .ended(reason):
            var record = brokenCoverageRecord(
                report: report,
                revision: revision,
                receivedAt: receivedAt,
                prior: prior,
                ordinal: ordinal,
                reason: reason
            )
            record.state = .ended(reason)
            projection.coverage[report.streamID] = record
            projection.checkpointRequiredAfterSequence = max(
                projection.checkpointRequiredAfterSequence ?? 0,
                revision.sequence
            )
        }

        state.projections[revision.sourceEpoch] = projection
        enforceCoverageLimit(
            in: revision.sourceEpoch,
            after: revision.sequence,
            receivedAt: receivedAt,
            state: &state
        )
    }

    func materializeExpiredCoverage(
        in projection: inout SourceProjection,
        receivedAt: UInt64,
        checkpointRequiredAfter sequence: UInt64,
        state: inout MemoryState
    ) {
        var foundExpiry = false
        for streamID in projection.coverage.keys {
            guard var lease = projection.coverage[streamID],
                  receivedAt >= lease.expiresAtReceiverMonotonicNs
            else {
                continue
            }
            switch lease.state {
            case .current:
                break
            case .broken where lease.awaitingBaseline:
                break
            case .broken, .ended:
                continue
            }
            lease.state = .broken(.producerPaused)
            lease.receivedAtReceiverMonotonicNs = receivedAt
            lease.expiresAtReceiverMonotonicNs = receivedAt
            lease.baselineSourceSequence = nil
            lease.awaitingBaseline = false
            lease.lastMutationOrdinal = state.takeOrdinal()
            projection.coverage[streamID] = lease
            foundExpiry = true
        }
        if foundExpiry {
            projection.checkpointRequiredAfterSequence = max(
                projection.checkpointRequiredAfterSequence ?? 0,
                sequence
            )
        }
    }

    func brokenCoverageRecord(
        report: CoverageReport,
        revision: SourceRevision,
        receivedAt: UInt64,
        prior: CoverageRecord?,
        ordinal: UInt64,
        reason: CoverageGapReason
    ) -> CoverageRecord {
        CoverageRecord(
            sourceEpoch: revision.sourceEpoch,
            streamID: report.streamID,
            scope: report.scope,
            lastContinuitySequence: report.continuitySequence,
            receivedAtReceiverMonotonicNs: receivedAt,
            expiresAtReceiverMonotonicNs: receivedAt,
            state: .broken(reason),
            guarantee: report.guarantee,
            coveredFields: Set(report.coveredFields),
            coveredEvidenceKinds: Set(report.coveredEvidenceKinds),
            maximumSilenceNs: prior?.maximumSilenceNs ?? 0,
            baselineSourceSequence: nil,
            awaitingBaseline: false,
            lastMutationOrdinal: ordinal
        )
    }

    func breakAllCoverage(
        in sourceEpoch: SceneSourceEpoch,
        reason: CoverageGapReason,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        guard var projection = state.projections[sourceEpoch] else { return }
        for streamID in projection.coverage.keys {
            guard var record = projection.coverage[streamID] else { continue }
            record.state = .broken(reason)
            record.receivedAtReceiverMonotonicNs = receivedAt
            record.expiresAtReceiverMonotonicNs = receivedAt
            record.baselineSourceSequence = nil
            record.awaitingBaseline = false
            record.lastMutationOrdinal = state.takeOrdinal()
            projection.coverage[streamID] = record
        }
        state.projections[sourceEpoch] = projection
    }

    func requireCheckpoint(
        in sourceEpoch: SceneSourceEpoch,
        after sequence: UInt64,
        state: inout MemoryState
    ) {
        var projection = state.projections[sourceEpoch] ?? SourceProjection()
        projection.checkpointRequiredAfterSequence = max(
            projection.checkpointRequiredAfterSequence ?? 0,
            sequence
        )
        state.projections[sourceEpoch] = projection
    }

    func enforceCoverageLimit(
        in sourceEpoch: SceneSourceEpoch,
        after sequence: UInt64,
        receivedAt: UInt64,
        state: inout MemoryState
    ) {
        guard var projection = state.projections[sourceEpoch] else { return }
        var lostCompleteContinuity = false
        while projection.coverage.count > limits.maximumCoverageStreamsPerSource {
            let victim = projection.coverage.values.sorted { lhs, rhs in
                if lhs.lastMutationOrdinal != rhs.lastMutationOrdinal {
                    return lhs.lastMutationOrdinal < rhs.lastMutationOrdinal
                }
                return lhs.streamID.description < rhs.streamID.description
            }.first
            guard let victim else { break }
            if victim.guarantee == .completeEvents,
               victim.baselineSourceSequence != nil || victim.awaitingBaseline
            {
                lostCompleteContinuity = true
            }
            projection.coverage.removeValue(forKey: victim.streamID)
        }
        if lostCompleteContinuity {
            projection.checkpointRequiredAfterSequence = max(
                projection.checkpointRequiredAfterSequence ?? 0,
                sequence
            )
            for streamID in projection.coverage.keys {
                guard var lease = projection.coverage[streamID],
                      lease.guarantee == .completeEvents
                else {
                    continue
                }
                lease.state = .broken(.sourceBackpressure)
                lease.receivedAtReceiverMonotonicNs = receivedAt
                lease.baselineSourceSequence = nil
                lease.awaitingBaseline = true
                lease.lastMutationOrdinal = state.takeOrdinal()
                projection.coverage[streamID] = lease
            }
        }
        state.projections[sourceEpoch] = projection
    }

    func recordReplay(_ event: SceneEventEnvelope, state: inout MemoryState) {
        var projection = state.projections[event.revision.sourceEpoch] ?? SourceProjection()
        let ordinal = state.takeOrdinal()
        projection.replayLedger[event.revision.sequence] = ReplayEntry(
            envelope: event,
            acceptedOrdinal: ordinal,
            estimatedBytes: estimate(event)
        )
        while projection.replayLedger.count > limits.maximumReplayEntriesPerSource {
            let victim = projection.replayLedger.values.sorted { lhs, rhs in
                if lhs.acceptedOrdinal != rhs.acceptedOrdinal {
                    return lhs.acceptedOrdinal < rhs.acceptedOrdinal
                }
                return lhs.envelope.revision.sequence < rhs.envelope.revision.sequence
            }.first
            guard let victim else { break }
            projection.replayLedger.removeValue(forKey: victim.envelope.revision.sequence)
        }
        state.projections[event.revision.sourceEpoch] = projection
    }
}

// MARK: - Lookup and freshness

private enum EmptyFieldSelection {
    case all
    case none
}

private extension SceneMemoryStore {
    func makeObjectLookup(
        _ object: StoredObject,
        matchedRegion: SurfaceRegion?,
        requestedFields: [SceneFieldKey],
        emptyFieldSelection: EmptyFieldSelection,
        now: UInt64
    ) -> SceneObjectLookup {
        let fieldKeys: [SceneFieldKey]
        if requestedFields.isEmpty {
            switch emptyFieldSelection {
            case .all:
                fieldKeys = object.fields.keys.sorted()
            case .none:
                fieldKeys = []
            }
        } else {
            fieldKeys = Array(Set(requestedFields)).sorted()
        }
        let fields = fieldKeys.map { field -> SceneFieldLookup in
            guard let stored = object.fields[field] else {
                return SceneFieldLookup(
                    field: field,
                    value: nil,
                    knowledge: nil,
                    confidence: nil,
                    sensitivity: .unknown,
                    evidence: [],
                    sourceRevision: nil,
                    observedAtSourceMonotonicNs: nil,
                    receivedAtReceiverMonotonicNs: nil,
                    freshness: .unknown
                )
            }
            return SceneFieldLookup(
                field: field,
                value: stored.value,
                knowledge: stored.knowledge,
                confidence: stored.confidence,
                sensitivity: stored.sensitivity,
                evidence: stored.evidence,
                sourceRevision: stored.revision,
                observedAtSourceMonotonicNs: stored.observedAtSourceMonotonicNs,
                receivedAtReceiverMonotonicNs: stored.receivedAtReceiverMonotonicNs,
                freshness: freshness(of: stored, in: object, now: now)
            )
        }
        return SceneObjectLookup(
            canonicalID: object.canonicalID,
            sourceObject: object.sourceObject,
            parent: object.parent,
            matchedRegion: matchedRegion,
            fields: fields
        )
    }

    func freshness(
        of field: StoredField,
        in object: StoredObject,
        now: UInt64
    ) -> SceneFieldFreshness {
        guard isActive(object.sourceObject.sourceEpoch) else { return .historical }
        guard field.sensitivity == .ordinary else { return .unknown }
        if object.objectTombstone != nil ||
            object.fieldTombstones[field.field] != nil ||
            field.invalidation != nil ||
            hasStaleDependency(field, owner: object, state: state)
        {
            return .stale
        }
        guard let projection = state.projections[object.sourceObject.sourceEpoch] else {
            return .unknown
        }
        if projection.coverage.values.contains(where: { lease in
            coverage(
                lease,
                verifies: field,
                object: object,
                now: now
            )
        }), dependenciesAreVerified(field, owner: object, now: now)
        {
            return .verifiedCurrent
        }
        return .provisional
    }

    func hasStaleDependency(
        _ field: StoredField,
        owner: StoredObject,
        state memoryState: MemoryState
    ) -> Bool {
        var remainingNodes = maximumDependencyTraversalNodes
        var path = Set<StoredFieldNode>()
        return hasStaleDependency(
            field,
            owner: owner,
            state: memoryState,
            depth: 0,
            remainingNodes: &remainingNodes,
            path: &path
        )
    }

    func hasStaleDependency(
        _ field: StoredField,
        owner: StoredObject,
        state memoryState: MemoryState,
        depth: Int,
        remainingNodes: inout Int,
        path: inout Set<StoredFieldNode>
    ) -> Bool {
        guard depth < maximumDependencyTraversalDepth, remainingNodes > 0 else {
            return !field.dependencies.isEmpty
        }
        guard !field.dependencies.isEmpty else { return false }
        let node = StoredFieldNode(object: owner.sourceObject, field: field.field)
        guard path.insert(node).inserted else { return true }
        remainingNodes -= 1
        defer { path.remove(node) }

        for dependency in field.dependencies {
            let dependencyEpoch = dependency.revision.sourceEpoch
            guard memoryState.activeEpochBySource[dependencyEpoch.source] == dependencyEpoch,
                  let projection = memoryState.projections[dependencyEpoch],
                  projection.lastAcceptedSequence >= dependency.revision.sequence
            else {
                return true
            }

            let targetKey: SourceObjectKey?
            if let explicit = dependency.object {
                targetKey = explicit
            } else if dependency.field != nil {
                targetKey = owner.sourceObject
            } else {
                // Without a narrower object or field scope, every later event from
                // the referenced source may change the basis of the derived claim.
                if projection.lastAcceptedSequence > dependency.revision.sequence {
                    return true
                }
                for target in projection.objects.values.sorted(by: objectSortPrecedes) {
                    for key in target.fields.keys.sorted() {
                        guard let candidate = target.fields[key],
                              candidate.revision.sequence == dependency.revision.sequence
                        else {
                            continue
                        }
                        if hasStaleDependency(
                            candidate,
                            owner: target,
                            state: memoryState,
                            depth: depth + 1,
                            remainingNodes: &remainingNodes,
                            path: &path
                        ) {
                            return true
                        }
                    }
                }
                continue
            }
            guard let targetKey else { return true }
            guard let target = projection.objects[targetKey.objectID] else {
                return true
            }
            if let tombstone = target.objectTombstone,
               tombstone.revision.sequence >= dependency.revision.sequence
            {
                return true
            }
            if let dependentField = dependency.field {
                if let tombstone = target.fieldTombstones[dependentField],
                   tombstone.revision.sequence >= dependency.revision.sequence
                {
                    return true
                }
                guard let current = target.fields[dependentField] else { return true }
                if current.revision.sequence > dependency.revision.sequence ||
                    (current.invalidation?.revision.sequence ?? 0) >=
                        dependency.revision.sequence
                {
                    return true
                }
                if hasStaleDependency(
                    current,
                    owner: target,
                    state: memoryState,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    path: &path
                ) {
                    return true
                }
            } else {
                if target.fieldTombstones.values.contains(where: {
                    $0.revision.sequence >= dependency.revision.sequence
                }) {
                    return true
                }
                if target.fields.values.contains(where: { candidate in
                    candidate.revision.sequence > dependency.revision.sequence ||
                        (candidate.invalidation?.revision.sequence ?? 0) >=
                            dependency.revision.sequence
                }) {
                    return true
                }
                for key in target.fields.keys.sorted() {
                    guard let candidate = target.fields[key] else { continue }
                    if hasStaleDependency(
                        candidate,
                        owner: target,
                        state: memoryState,
                        depth: depth + 1,
                        remainingNodes: &remainingNodes,
                        path: &path
                    ) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func dependenciesAreVerified(
        _ field: StoredField,
        owner: StoredObject,
        now: UInt64
    ) -> Bool {
        var remainingNodes = maximumDependencyTraversalNodes
        var path = Set<StoredFieldNode>()
        return dependenciesAreVerified(
            field,
            owner: owner,
            now: now,
            depth: 0,
            remainingNodes: &remainingNodes,
            path: &path
        )
    }

    func dependenciesAreVerified(
        _ field: StoredField,
        owner: StoredObject,
        now: UInt64,
        depth: Int,
        remainingNodes: inout Int,
        path: inout Set<StoredFieldNode>
    ) -> Bool {
        guard !field.dependencies.isEmpty else { return true }
        guard depth < maximumDependencyTraversalDepth, remainingNodes > 0 else {
            return false
        }
        let node = StoredFieldNode(object: owner.sourceObject, field: field.field)
        guard path.insert(node).inserted else { return false }
        remainingNodes -= 1
        defer { path.remove(node) }

        for dependency in field.dependencies {
            // Object-wide and revision-wide dependencies have no field-specific
            // complete-coverage proof, so they deliberately cap trust at provisional.
            guard let dependentField = dependency.field else { return false }
            let targetKey = dependency.object ?? owner.sourceObject
            guard let projection = state.projections[dependency.revision.sourceEpoch],
                  let target = projection.objects[targetKey.objectID],
                  let current = target.fields[dependentField]
            else {
                return false
            }
            if !dependenciesAreVerified(
                current,
                owner: target,
                now: now,
                depth: depth + 1,
                remainingNodes: &remainingNodes,
                path: &path
            ) {
                return false
            }
            if !projection.coverage.values.contains(where: { lease in
                coverage(lease, verifies: current, object: target, now: now)
            }) {
                return false
            }
        }
        return true
    }

    func purgePrivacyDependentValues(state memoryState: inout MemoryState) {
        let nodes = memoryState.projections.values.flatMap { projection in
            projection.objects.values.flatMap { object in
                object.fields.keys.map {
                    StoredFieldNode(object: object.sourceObject, field: $0)
                }
            }
        }.sorted { lhs, rhs in
            let lhsKey = "\(sourceObjectSortKey(lhs.object)):\(lhs.field.rawValue)"
            let rhsKey = "\(sourceObjectSortKey(rhs.object)):\(rhs.field.rawValue)"
            return lhsKey < rhsKey
        }

        var purge: [StoredFieldNode] = []
        for node in nodes {
            guard let object = memoryState.projections[node.object.sourceEpoch]?
                .objects[node.object.objectID],
                let field = object.fields[node.field],
                !field.dependencies.isEmpty
            else {
                continue
            }
            var remainingNodes = maximumDependencyTraversalNodes
            var path = Set<StoredFieldNode>()
            if hasPrivacyTaintedDependency(
                field,
                owner: object,
                state: memoryState,
                depth: 0,
                remainingNodes: &remainingNodes,
                path: &path
            ) {
                purge.append(node)
            }
        }

        var affectedEpochs = Set<SceneSourceEpoch>()
        for node in purge {
            guard var projection = memoryState.projections[node.object.sourceEpoch],
                  var object = projection.objects[node.object.objectID],
                  var field = object.fields[node.field]
            else {
                continue
            }
            field.value = nil
            object.fields[node.field] = field
            object.lastMutationOrdinal = memoryState.takeOrdinal()
            projection.objects[node.object.objectID] = object
            memoryState.projections[node.object.sourceEpoch] = projection
            affectedEpochs.insert(node.object.sourceEpoch)
        }
        for epoch in affectedEpochs {
            memoryState.projections[epoch]?.replayLedger.removeAll(keepingCapacity: false)
        }
    }

    /// An evicted derived object no longer appears in the live field graph, but
    /// its replay envelope may still hold the derived bytes. Keep direct replay
    /// idempotency while dropping every value-bearing dependency envelope at a
    /// privacy, checkpoint, or eviction boundary.
    func purgePotentiallyDependentReplayPayloads(
        state memoryState: inout MemoryState
    ) {
        for epoch in Array(memoryState.projections.keys) {
            guard var projection = memoryState.projections[epoch] else { continue }
            projection.replayLedger = projection.replayLedger.filter { _, entry in
                    !containsPotentiallyDerivedValue(entry.envelope)
                }
            memoryState.projections[epoch] = projection
        }
    }

    func hasPrivacyTaintedDependency(
        _ field: StoredField,
        owner: StoredObject,
        state memoryState: MemoryState,
        depth: Int,
        remainingNodes: inout Int,
        path: inout Set<StoredFieldNode>
    ) -> Bool {
        guard field.sensitivity == .ordinary else { return true }
        guard !field.dependencies.isEmpty else { return false }
        guard depth < maximumDependencyTraversalDepth, remainingNodes > 0 else {
            return true
        }
        let node = StoredFieldNode(object: owner.sourceObject, field: field.field)
        guard path.insert(node).inserted else { return true }
        remainingNodes -= 1
        defer { path.remove(node) }

        for dependency in field.dependencies {
            guard let projection = memoryState.projections[dependency.revision.sourceEpoch],
                  projection.lastAcceptedSequence >= dependency.revision.sequence
            else {
                return true
            }
            if privacyFloorCovers(dependency, owner: owner, in: projection) { return true }

            if dependency.object == nil, dependency.field == nil {
                for target in projection.objects.values.sorted(by: objectSortPrecedes) {
                    for key in target.fields.keys.sorted() {
                        guard let candidate = target.fields[key],
                              candidate.revision.sequence <= dependency.revision.sequence
                        else {
                            continue
                        }
                        if candidate.sensitivity != .ordinary { return true }
                        if hasPrivacyTaintedDependency(
                            candidate,
                            owner: target,
                            state: memoryState,
                            depth: depth + 1,
                            remainingNodes: &remainingNodes,
                            path: &path
                        ) {
                            return true
                        }
                    }
                }
                continue
            }

            let targetKey = dependency.object ?? owner.sourceObject
            guard targetKey.sourceEpoch == dependency.revision.sourceEpoch,
                  let target = projection.objects[targetKey.objectID]
            else {
                return true
            }
            if let dependentField = dependency.field {
                if let marker = target.fieldTombstones[dependentField],
                   marker.reason == .privacyBoundary,
                   marker.revision.sequence >= dependency.revision.sequence
                {
                    return true
                }
                guard let candidate = target.fields[dependentField] else { return true }
                if let marker = candidate.invalidation,
                   marker.reason == .privacyBoundary,
                   marker.revision.sequence >= dependency.revision.sequence
                {
                    return true
                }
                if candidate.sensitivity != .ordinary { return true }
                if hasPrivacyTaintedDependency(
                    candidate,
                    owner: target,
                    state: memoryState,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    path: &path
                ) {
                    return true
                }
            } else {
                if let marker = target.objectTombstone,
                   marker.reason == .privacyBoundary,
                   marker.revision.sequence >= dependency.revision.sequence
                {
                    return true
                }
                if target.fieldTombstones.values.contains(where: {
                    $0.reason == .privacyBoundary &&
                        $0.revision.sequence >= dependency.revision.sequence
                }) {
                    return true
                }
                for key in target.fields.keys.sorted() {
                    guard let candidate = target.fields[key] else { continue }
                    if let marker = candidate.invalidation,
                       marker.reason == .privacyBoundary,
                       marker.revision.sequence >= dependency.revision.sequence
                    {
                        return true
                    }
                    if candidate.sensitivity != .ordinary {
                        return true
                    }
                    if hasPrivacyTaintedDependency(
                        candidate,
                        owner: target,
                        state: memoryState,
                        depth: depth + 1,
                        remainingNodes: &remainingNodes,
                        path: &path
                    ) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func privacyFloorCovers(
        _ dependency: SceneClaimDependency,
        owner: StoredObject,
        in projection: SourceProjection
    ) -> Bool {
        let sequence = dependency.revision.sequence
        if let floor = projection.privacyProjectionFloor, floor >= sequence {
            return true
        }
        let effectiveObject = dependency.object ??
            (dependency.field == nil ? nil : owner.sourceObject)
        guard let object = effectiveObject else {
            if dependency.field == nil,
               let floor = projection.privacyRevisionWideFloor,
               floor >= sequence
            {
                return true
            }
            return false
        }
        if let floor = projection.privacyObjectFloors[object.objectID], floor >= sequence {
            return true
        }
        if let field = dependency.field {
            if let floor = projection.privacyFieldFloors[field], floor >= sequence {
                return true
            }
            let key = PrivacyObjectFieldKey(objectID: object.objectID, field: field)
            return projection.privacyObjectFieldFloors[key].map { $0 >= sequence } == true
        }
        if projection.privacyFieldFloors.values.contains(where: { $0 >= sequence }) {
            return true
        }
        return projection.privacyObjectFieldFloors.contains { key, floor in
            key.objectID == object.objectID && floor >= sequence
        }
    }

    func coverage(
        _ lease: CoverageRecord,
        verifies field: StoredField,
        object: StoredObject,
        now: UInt64
    ) -> Bool {
        guard case .current = lease.state,
              lease.guarantee == .completeEvents,
              now < lease.expiresAtReceiverMonotonicNs,
              grantIsCurrent(for: object.sourceObject.sourceEpoch, now: now),
              let baseline = lease.baselineSourceSequence,
              field.revision.sequence >= baseline,
              lease.coveredFields.contains(field.field)
        else {
            return false
        }
        let evidenceKinds = Set(field.evidence.map(\.kind))
        guard !evidenceKinds.isEmpty,
              evidenceKinds.isSubset(of: lease.coveredEvidenceKinds)
        else {
            return false
        }

        switch lease.scope {
        case let .object(key):
            return key == object.sourceObject
        case let .sourceProjection(epoch):
            return epoch == object.sourceObject.sourceEpoch
        case let .surface(surface):
            return object.fields.values.contains { candidate in
                guard candidate.invalidation == nil,
                      case let .region(region) = candidate.value
                else { return false }
                return region.coordinateSpace.surface == surface
            }
        case let .region(coveredRegion):
            return object.fields.values.contains { candidate in
                guard candidate.invalidation == nil,
                      case let .region(objectRegion) = candidate.value,
                      objectRegion.coordinateSpace == coveredRegion.coordinateSpace
                else { return false }
                return contains(coveredRegion.rect, rect: objectRegion.rect)
            }
        }
    }

    func grantIsCurrent(for epoch: SceneSourceEpoch, now: UInt64) -> Bool {
        guard let registration = state.registrationsByHandle.values.first(where: {
            $0.handle.sourceEpoch == epoch
        }) else {
            return false
        }
        guard let expiry = registration.grant.expiresAtReceiverMonotonicNs else {
            return true
        }
        return now < expiry
    }

    func isActive(_ epoch: SceneSourceEpoch) -> Bool {
        state.activeEpochBySource[epoch.source] == epoch
    }
}

// MARK: - Bounds and index

private extension SceneMemoryStore {
    func scopedPrivacyRevisionFloorCount(_ projection: SourceProjection) -> Int {
        projection.privacyFieldFloors.count +
            projection.privacyObjectFloors.count +
            projection.privacyObjectFieldFloors.count
    }

    func privacyRevisionFloorCount(_ projection: SourceProjection) -> Int {
        scopedPrivacyRevisionFloorCount(projection) +
            (projection.privacyRevisionWideFloor == nil ? 0 : 1) +
            (projection.privacyProjectionFloor == nil ? 0 : 1)
    }

    @discardableResult
    func enforceBudgets(state: inout MemoryState) -> Bool {
        var didEvictObjects = false
        while exceedsObjectCountOrFieldBudget(state) {
            let objects = state.projections.values.flatMap { $0.objects.values }
            guard let victim = objects.sorted(by: objectEvictionPrecedes).first else { break }
            state.projections[victim.sourceObject.sourceEpoch]?
                .objects.removeValue(forKey: victim.sourceObject.objectID)
            didEvictObjects = true
        }

        // Replay comparisons are useful but reconstructable. Shed their oldest exact
        // payloads before evicting current scene objects for the byte-ish budget.
        while estimatedTotalBytes(state) > limits.maximumEstimatedBytes {
            let replay = state.projections.values.flatMap { $0.replayLedger.values }
            guard let victim = replay.sorted(by: replayEvictionPrecedes).first else { break }
            state.projections[victim.envelope.revision.sourceEpoch]?
                .replayLedger.removeValue(forKey: victim.envelope.revision.sequence)
        }

        while estimatedTotalBytes(state) > limits.maximumEstimatedBytes {
            let objects = state.projections.values.flatMap { $0.objects.values }
            guard let victim = objects.sorted(by: objectEvictionPrecedes).first else { break }
            state.projections[victim.sourceObject.sourceEpoch]?
                .objects.removeValue(forKey: victim.sourceObject.objectID)
            didEvictObjects = true
        }
        return didEvictObjects
    }

    func exceedsObjectCountOrFieldBudget(_ state: MemoryState) -> Bool {
        let objects = state.projections.values.flatMap { $0.objects.values }
        let fields = objects.reduce(0) { $0 + $1.fields.count }
        return objects.count > limits.maximumObjects ||
            fields > limits.maximumFields
    }

    func rebuildSpatialIndex(state: inout MemoryState) {
        let frontmostWindowIndexByProcess = frontmostVisibleWindowIndexByProcess(in: state)
        var candidates: [SceneHotSpatialCandidate] = []
        var dependencyFloors: [SceneSourceEpoch: UInt64] = [:]
        for (epoch, projection) in state.projections {
            for object in projection.objects.values where object.objectTombstone == nil {
                let isOnScreen = ordinaryBoolean(
                    windowIsOnScreenField,
                    in: object
                )
                let alpha = ordinaryNumber(windowAlphaField, in: object)
                guard isOnScreen != false, alpha.map({ $0 > 0 }) != false,
                      let geometryField = usableOrdinaryField(
                          geometryBoundsField,
                          in: object
                      ),
                      case let .region(region) = geometryField.value
                else {
                    continue
                }

                let isHistorical = state.activeEpochBySource[epoch.source] != epoch
                let evidenceKinds = Set(geometryField.evidence.map(\.kind))
                let directIndex = ordinaryUnsignedInteger(
                    windowFrontToBackIndexField,
                    in: object
                )
                let inferredIndex: UInt64?
                if directIndex == nil, !isHistorical,
                   evidenceKinds.contains(.accessibility),
                   let processID = ordinaryProcessID(in: object)
                {
                    inferredIndex = frontmostWindowIndexByProcess[
                        DeviceProcessKey(
                            device: epoch.source.device,
                            processID: processID
                        )
                    ]
                } else {
                    inferredIndex = nil
                }
                let frontToBackIndex = directIndex ?? inferredIndex
                let stackingBasis: SceneHotSpatialStackingBasis?
                if directIndex != nil {
                    stackingBasis = .directWindow
                } else if inferredIndex != nil {
                    stackingBasis = .inferredApplicationWindow
                } else {
                    stackingBasis = nil
                }
                let dependencyStale = hasStaleDependency(
                    geometryField,
                    owner: object,
                    state: state
                )
                candidates.append(
                    SceneHotSpatialCandidate(
                        canonicalID: object.canonicalID,
                        sourceObject: object.sourceObject,
                        region: region,
                        geometryField: geometryField.field,
                        evidenceKinds: evidenceKinds,
                        receivedAtReceiverMonotonicNs:
                            geometryField.receivedAtReceiverMonotonicNs,
                        isHistorical: isHistorical,
                        isDependencyStale: dependencyStale,
                        frontToBackIndex: frontToBackIndex,
                        stackingBasis: stackingBasis,
                        isOnScreen: isOnScreen,
                        alpha: alpha
                    )
                )
                if !dependencyStale {
                    var remainingNodes = maximumDependencyTraversalNodes
                    var path = Set<StoredFieldNode>()
                    collectRevisionWideDependencyFloors(
                        geometryField,
                        owner: object,
                        state: state,
                        depth: 0,
                        remainingNodes: &remainingNodes,
                        path: &path,
                        floors: &dependencyFloors
                    )
                }
            }
        }
        if state.spatialSnapshotRevision < UInt64.max {
            state.spatialSnapshotRevision += 1
        }
        state.spatialSnapshot = SceneSpatialSnapshot(
            revision: state.spatialSnapshotRevision,
            candidates: candidates
        )
        state.spatialRevisionWideDependencyFloor = dependencyFloors
    }

    func usableOrdinaryField(
        _ key: SceneFieldKey,
        in object: StoredObject
    ) -> StoredField? {
        guard object.objectTombstone == nil,
              object.fieldTombstones[key] == nil,
              let field = object.fields[key],
              field.sensitivity == .ordinary,
              field.invalidation == nil
        else {
            return nil
        }
        return field
    }

    func ordinaryBoolean(
        _ key: SceneFieldKey,
        in object: StoredObject
    ) -> Bool? {
        guard let field = usableOrdinaryField(key, in: object),
              case let .boolean(value) = field.value
        else {
            return nil
        }
        return value
    }

    func ordinaryNumber(
        _ key: SceneFieldKey,
        in object: StoredObject
    ) -> Double? {
        guard let field = usableOrdinaryField(key, in: object),
              case let .number(value) = field.value
        else {
            return nil
        }
        return value
    }

    func ordinaryUnsignedInteger(
        _ key: SceneFieldKey,
        in object: StoredObject
    ) -> UInt64? {
        guard let field = usableOrdinaryField(key, in: object),
              case let .unsignedInteger(value) = field.value
        else {
            return nil
        }
        return value
    }

    func ordinaryProcessID(in object: StoredObject) -> Int64? {
        guard let field = usableOrdinaryField(applicationPIDField, in: object) else {
            return nil
        }
        switch field.value {
        case let .signedInteger(value) where value >= 0:
            return value
        case let .unsignedInteger(value) where value <= UInt64(Int64.max):
            return Int64(value)
        default:
            return nil
        }
    }

    func frontmostVisibleWindowIndexByProcess(
        in memoryState: MemoryState
    ) -> [DeviceProcessKey: UInt64] {
        var result: [DeviceProcessKey: UInt64] = [:]
        for (epoch, projection) in memoryState.projections
            where memoryState.activeEpochBySource[epoch.source] == epoch
        {
            for object in projection.objects.values where object.objectTombstone == nil {
                guard ordinaryBoolean(windowIsOnScreenField, in: object) != false,
                      ordinaryNumber(windowAlphaField, in: object).map({ $0 > 0 }) != false,
                      let processID = ordinaryProcessID(in: object),
                      let index = ordinaryUnsignedInteger(
                          windowFrontToBackIndexField,
                          in: object
                      )
                else {
                    continue
                }
                let key = DeviceProcessKey(
                    device: epoch.source.device,
                    processID: processID
                )
                result[key] = min(result[key] ?? UInt64.max, index)
            }
        }
        return result
    }

    func collectRevisionWideDependencyFloors(
        _ field: StoredField,
        owner: StoredObject,
        state memoryState: MemoryState,
        depth: Int,
        remainingNodes: inout Int,
        path: inout Set<StoredFieldNode>,
        floors: inout [SceneSourceEpoch: UInt64]
    ) {
        guard !field.dependencies.isEmpty,
              depth < maximumDependencyTraversalDepth,
              remainingNodes > 0
        else {
            return
        }
        let node = StoredFieldNode(object: owner.sourceObject, field: field.field)
        guard path.insert(node).inserted else { return }
        remainingNodes -= 1
        defer { path.remove(node) }

        for dependency in field.dependencies {
            guard let projection = memoryState.projections[dependency.revision.sourceEpoch]
            else {
                continue
            }
            if dependency.object == nil, dependency.field == nil {
                let prior = floors[dependency.revision.sourceEpoch] ?? UInt64.max
                floors[dependency.revision.sourceEpoch] = min(
                    prior,
                    dependency.revision.sequence
                )
                for target in projection.objects.values.sorted(by: objectSortPrecedes) {
                    for key in target.fields.keys.sorted() {
                        guard let candidate = target.fields[key],
                              candidate.revision.sequence == dependency.revision.sequence
                        else {
                            continue
                        }
                        collectRevisionWideDependencyFloors(
                            candidate,
                            owner: target,
                            state: memoryState,
                            depth: depth + 1,
                            remainingNodes: &remainingNodes,
                            path: &path,
                            floors: &floors
                        )
                    }
                }
                continue
            }

            let targetKey = dependency.object ?? owner.sourceObject
            guard let target = projection.objects[targetKey.objectID] else { continue }
            if let dependentField = dependency.field {
                guard let candidate = target.fields[dependentField] else { continue }
                collectRevisionWideDependencyFloors(
                    candidate,
                    owner: target,
                    state: memoryState,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    path: &path,
                    floors: &floors
                )
            } else {
                for key in target.fields.keys.sorted() {
                    guard let candidate = target.fields[key] else { continue }
                    collectRevisionWideDependencyFloors(
                        candidate,
                        owner: target,
                        state: memoryState,
                        depth: depth + 1,
                        remainingNodes: &remainingNodes,
                        path: &path,
                        floors: &floors
                    )
                }
            }
        }
    }

    func estimatedTotalBytes(_ state: MemoryState) -> Int {
        var total = 0
        for projection in state.projections.values {
            total += projection.replayLedger.values.reduce(0) {
                $0 + $1.estimatedBytes
            }
            total += projection.coverage.count * 256
            total += projection.retiredObjectIDs.count * 96
            total += privacyRevisionFloorCount(projection) * 96
            for object in projection.objects.values {
                total += estimate(object)
            }
        }
        return total
    }

    func estimate(_ object: StoredObject) -> Int {
        256 + object.fields.values.reduce(0) { $0 + estimate($1) } +
            object.fieldTombstones.count * 96
    }

    func estimate(_ field: StoredField) -> Int {
        var bytes = 192 + field.field.rawValue.utf8.count
        bytes += field.evidence.reduce(0) { partial, evidence in
            partial + 48 + (evidence.detailCode?.utf8.count ?? 0)
        }
        bytes += field.dependencies.count * 80
        switch field.value {
        case let .text(value), let .digest(value):
            bytes += value.utf8.count
        case let .textList(values):
            bytes += values.reduce(0) { $0 + $1.utf8.count + 16 }
        case .boolean, .signedInteger, .unsignedInteger, .number:
            bytes += 8
        case .region:
            bytes += 128
        case nil:
            break
        }
        return bytes
    }

    func estimate(_ event: SceneEventEnvelope) -> Int {
        // Contract values are already bounded. This deliberately conservative estimate
        // is used only for eviction, not serialization or protocol framing.
        switch event.payload {
        case let .observation(observation):
            return 192 + observation.claims.reduce(0) { partial, claim in
                partial + 160 + claim.field.rawValue.utf8.count + estimate(claim.value)
            }
        case let .checkpoint(checkpoint):
            return 192 + checkpoint.observations.reduce(0) { partial, observation in
                partial + observation.claims.reduce(0) { claimBytes, claim in
                    claimBytes + 160 + claim.field.rawValue.utf8.count + estimate(claim.value)
                }
            }
        case let .invalidation(invalidation):
            return 160 + invalidation.fields.reduce(0) { $0 + $1.rawValue.utf8.count }
        case let .coverage(report):
            return 192 + report.coveredFields.reduce(0) { $0 + $1.rawValue.utf8.count }
        }
    }

    func estimate(_ value: SceneFieldValue?) -> Int {
        switch value {
        case let .text(value), let .digest(value):
            return value.utf8.count
        case let .textList(values):
            return values.reduce(0) { $0 + $1.utf8.count + 16 }
        case .region:
            return 128
        case .boolean, .signedInteger, .unsignedInteger, .number:
            return 8
        case nil:
            return 0
        }
    }

    func objectEvictionPrecedes(_ lhs: StoredObject, _ rhs: StoredObject) -> Bool {
        if lhs.lastMutationOrdinal != rhs.lastMutationOrdinal {
            return lhs.lastMutationOrdinal < rhs.lastMutationOrdinal
        }
        return sourceObjectSortKey(lhs.sourceObject) < sourceObjectSortKey(rhs.sourceObject)
    }

    func replayEvictionPrecedes(_ lhs: ReplayEntry, _ rhs: ReplayEntry) -> Bool {
        if lhs.acceptedOrdinal != rhs.acceptedOrdinal {
            return lhs.acceptedOrdinal < rhs.acceptedOrdinal
        }
        return sourceRevisionSortKey(lhs.envelope.revision) <
            sourceRevisionSortKey(rhs.envelope.revision)
    }
}

// MARK: - Receipts

private extension SceneMemoryStore {
    func receipt(
        batch: SceneEventBatch,
        rejection: IngestRejectionCode
    ) -> IngestReceipt {
        makeReceipt(
            batchID: batch.batchID,
            status: .rejected,
            acceptedThrough: nil,
            identicalReplays: [],
            gaps: [],
            rejection: rejection
        )
    }

    func makeReceipt(
        batchID: UUID,
        status: IngestReceiptStatus,
        acceptedThrough: SourceRevision?,
        identicalReplays: [SourceRevision],
        gaps: [SourceSequenceGap],
        rejection: IngestRejectionCode?
    ) -> IngestReceipt {
        // All values are already bounded by SceneEventBatch and the replay pass.
        try! IngestReceipt(
            batchID: batchID,
            status: status,
            acceptedThrough: acceptedThrough,
            identicalReplays: identicalReplays,
            sequenceGaps: gaps,
            rejection: rejection
        )
    }
}

// MARK: - Pure helpers

private func containsNonordinaryClaim(_ event: SceneEventEnvelope) -> Bool {
    switch event.payload {
    case let .observation(observation):
        observation.claims.contains { $0.sensitivity != .ordinary }
    case let .checkpoint(checkpoint):
        checkpoint.observations.contains { observation in
            observation.claims.contains { $0.sensitivity != .ordinary }
        }
    case .invalidation, .coverage:
        false
    }
}

private func requiresPrivacyDependencyReevaluation(
    _ event: SceneEventEnvelope
) -> Bool {
    switch event.payload {
    case let .observation(observation):
        observation.claims.contains {
            $0.sensitivity != .ordinary || !$0.dependencies.isEmpty
        }
    case .checkpoint:
        // A checkpoint replaces the complete source projection. Omissions can
        // make a dependency unresolvable and must purge any derived value that
        // can no longer be proven ordinary.
        true
    case let .invalidation(invalidation):
        invalidation.reason == .privacyBoundary
    case .coverage:
        false
    }
}

private func containsPotentiallyDerivedValue(_ event: SceneEventEnvelope) -> Bool {
    switch event.payload {
    case let .observation(observation):
        observation.claims.contains {
            $0.value != nil && !$0.dependencies.isEmpty
        }
    case let .checkpoint(checkpoint):
        checkpoint.observations.contains { observation in
            observation.claims.contains {
                $0.value != nil && !$0.dependencies.isEmpty
            }
        }
    case .invalidation, .coverage:
        false
    }
}

private func addingSaturating(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
}

private func contains(_ outer: SceneRect, rect inner: SceneRect) -> Bool {
    inner.origin.x >= outer.origin.x &&
        inner.origin.y >= outer.origin.y &&
        inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width &&
        inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height
}

private func intersects(_ lhs: SurfaceRegion, _ rhs: SurfaceRegion) -> Bool {
    guard lhs.coordinateSpace == rhs.coordinateSpace else { return false }
    return lhs.rect.origin.x < rhs.rect.origin.x + rhs.rect.size.width &&
        rhs.rect.origin.x < lhs.rect.origin.x + lhs.rect.size.width &&
        lhs.rect.origin.y < rhs.rect.origin.y + rhs.rect.size.height &&
        rhs.rect.origin.y < lhs.rect.origin.y + lhs.rect.size.height
}

private func sourceObjectSortKey(_ key: SourceObjectKey) -> String {
    let source = key.sourceEpoch.source
    return [
        source.device.description,
        source.source.description,
        key.sourceEpoch.epochID.uuidString,
        key.objectID.description,
    ].joined(separator: ":")
}

private func objectSortPrecedes(_ lhs: StoredObject, _ rhs: StoredObject) -> Bool {
    sourceObjectSortKey(lhs.sourceObject) < sourceObjectSortKey(rhs.sourceObject)
}

private func sourceRevisionSortKey(_ revision: SourceRevision) -> String {
    "\(sourceObjectEpochSortKey(revision.sourceEpoch)):\(revision.sequence)"
}

private func sourceObjectEpochSortKey(_ epoch: SceneSourceEpoch) -> String {
    [
        epoch.source.device.description,
        epoch.source.source.description,
        epoch.epochID.uuidString,
    ].joined(separator: ":")
}
