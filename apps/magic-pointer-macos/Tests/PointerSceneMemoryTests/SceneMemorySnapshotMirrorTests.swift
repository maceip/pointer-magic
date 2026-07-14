import Foundation
import PointerSceneContracts
import PointerSceneMemory
import Testing

@Suite("Scene memory cache-first query mirror")
struct SceneMemorySnapshotMirrorTests {
    @Test("Accepted ingestion is immediately probeable without awaiting the actor")
    func immediateProbeAfterIngestion() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(1_000)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let object = fixture.object()
        let event = try fixture.observation(
            sequence: 1,
            object: object,
            coordinateSpace: fixture.coordinateSpace,
            label: "Save"
        )

        let receipt = await mirror.ingest(
            try SceneEventBatch(events: [event]),
            through: registration.handle
        )
        #expect(receipt.status == .accepted)

        let probe = mirror.probe(
            at: try ScenePoint(x: 15, y: 15),
            in: fixture.coordinateSpace
        )
        #expect(probe.candidates.map(\.spatial.sourceObject) == [object])
        #expect(probe.candidates.first?.state == .immediateCachedGeometry)
        #expect(probe.spatialSnapshotRevision > 0)
        #expect(probe.actionRequirement == .freshLiveAnchorRequired)
        #expect(!probe.authorizesSideEffects)
        #expect(probe.isComplete)

        let hydrated = await mirror.hydrate(
            probe,
            fields: [fixture.label, fixture.bounds]
        )
        #expect(hydrated.candidates.first?.fields.count == 2)
        #expect(hydrated.candidates.first?.state == .provisional)
        #expect(hydrated.actionRequirement == .freshLiveAnchorRequired)
        #expect(!hydrated.authorizesSideEffects)
    }

    @Test("Empty hydration selects no fields and requested fields are hard-capped")
    func hydrationFieldSelectionIsBounded() async throws {
        let fixture = try MirrorFixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let registration = try await fixture.register(store)
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: fixture.object(),
                    coordinateSpace: fixture.coordinateSpace,
                    label: "bounded"
                ),
            ]),
            through: registration.handle
        )
        let probe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )

        let empty = await mirror.hydrate(probe, fields: [])
        #expect(empty.requestedFields.isEmpty)
        #expect(empty.candidates.first?.object?.fields.isEmpty == true)
        #expect(empty.candidates.first?.fields.isEmpty == true)

        let requested = try (0 ..< 65).map {
            try SceneFieldKey("test.mirror.field.\($0)")
        }
        let bounded = await mirror.hydrate(probe, fields: requested)
        #expect(bounded.requestedFields == Array(requested.prefix(64)))
        #expect(bounded.didTruncateRequestedFields)
        #expect(bounded.candidates.first?.omittedExpiredFields.count == 64)
        #expect(!bounded.authorizesSideEffects)
    }

    @Test("Spatial probes require an exact coordinate-space revision")
    func exactCoordinateRevisionIsolation() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(10)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let oldObject = fixture.object()
        let newObject = fixture.object()
        let revisionTwo = try SurfaceCoordinateSpace(
            surface: fixture.surface,
            coordinateSpaceID: fixture.coordinateSpace.coordinateSpaceID,
            revision: 2
        )
        let oldEvent = try fixture.observation(
            sequence: 1,
            object: oldObject,
            coordinateSpace: fixture.coordinateSpace,
            label: "old layout"
        )
        let newEvent = try fixture.observation(
            sequence: 2,
            object: newObject,
            coordinateSpace: revisionTwo,
            label: "new layout"
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [oldEvent, newEvent]),
            through: registration.handle
        )
        let point = try ScenePoint(x: 20, y: 20)

        #expect(
            mirror.probe(at: point, in: fixture.coordinateSpace)
                .candidates.map(\.spatial.sourceObject) == [oldObject]
        )
        #expect(
            mirror.probe(at: point, in: revisionTwo)
                .candidates.map(\.spatial.sourceObject) == [newObject]
        )
    }

    @Test("An exact replay does not republish or advance the spatial revision")
    func replayIdempotence() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let event = try fixture.observation(
            sequence: 1,
            object: fixture.object(),
            coordinateSpace: fixture.coordinateSpace,
            label: "Replay me"
        )
        let batch = try SceneEventBatch(events: [event])
        _ = await mirror.ingest(batch, through: registration.handle)
        let revision = mirror.publishedSnapshotRevision
        let publications = mirror.snapshotPublicationCount

        let replay = await mirror.ingest(batch, through: registration.handle)
        #expect(replay.status == .accepted)
        #expect(replay.identicalReplays == [event.revision])
        #expect(mirror.publishedSnapshotRevision == revision)
        #expect(mirror.snapshotPublicationCount == publications)
    }

    @Test("Coverage start and heartbeat do not republish unchanged spatial state")
    func coverageHeartbeatDoesNotRepublish() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: fixture.object(),
                    coordinateSpace: fixture.coordinateSpace,
                    label: "stable geometry"
                ),
            ]),
            through: registration.handle
        )
        let revision = mirror.publishedSnapshotRevision
        let publications = mirror.snapshotPublicationCount
        let stream = CoverageStreamID()

        let started = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 2,
                    stream: stream,
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
            ]),
            through: registration.handle
        )
        let heartbeat = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 3,
                    stream: stream,
                    continuity: 2,
                    state: .heartbeat
                ),
            ]),
            through: registration.handle
        )

        #expect(started.status == .accepted)
        #expect(heartbeat.status == .accepted)
        #expect(mirror.publishedSnapshotRevision == revision)
        #expect(mirror.snapshotPublicationCount == publications)
    }

    @Test("Hydration propagates reducer staleness and retired-source history")
    func staleAndHistoricalPropagation() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(500)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let object = fixture.object()
        let observed = try fixture.observation(
            sequence: 1,
            object: object,
            coordinateSpace: fixture.coordinateSpace,
            label: "Mutable"
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [observed]),
            through: registration.handle
        )
        let probe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        let invalidated = try fixture.invalidation(
            sequence: 2,
            object: object,
            fields: [fixture.label]
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [invalidated]),
            through: registration.handle
        )

        let stale = await mirror.hydrate(probe, fields: [fixture.label])
        #expect(stale.candidates.first?.state == .stale)
        #expect(stale.candidates.first?.fields.first?.lookup.freshness == .stale)

        #expect(await store.closeSource(registration.handle))
        let historical = await mirror.hydrate(probe, fields: [fixture.label])
        #expect(historical.candidates.first?.state == .historical)
        #expect(historical.candidates.first?.fields.first?.lookup.freshness == .historical)
        #expect(await mirror.synchronizeSnapshot())
        let historicalProbe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        #expect(historicalProbe.candidates.first?.state == .historical)
    }

    @Test("Checkpoint omission retires an object ID and old probes cannot hydrate a reuse")
    func checkpointOmissionRetiresIdentity() async throws {
        let fixture = try MirrorFixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let registration = try await fixture.register(store)
        let object = fixture.object()
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: object,
                    coordinateSpace: fixture.coordinateSpace,
                    label: "original incarnation"
                ),
            ]),
            through: registration.handle
        )
        let oldProbe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        let oldCandidate = try #require(oldProbe.candidates.first)

        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 2, observations: []),
            ]),
            through: registration.handle
        )
        #expect(await store.lookup(object: object) == nil)

        let attemptedReuse = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 3,
                    object: object,
                    coordinateSpace: fixture.coordinateSpace,
                    label: "forbidden reuse"
                ),
            ]),
            through: registration.handle
        )
        #expect(attemptedReuse.status == .accepted)
        #expect(await store.lookup(object: object) == nil)
        #expect(await store.canonicalIdentity(for: object) == nil)
        #expect(
            mirror.probe(
                at: try ScenePoint(x: 10, y: 10),
                in: fixture.coordinateSpace
            ).candidates.isEmpty
        )

        let oldHydration = await mirror.hydrate(oldProbe, fields: [fixture.label])
        #expect(oldHydration.candidates.first?.cached.spatial.canonicalID ==
            oldCandidate.spatial.canonicalID)
        #expect(oldHydration.candidates.first?.object == nil)
        #expect(oldHydration.candidates.first?.fields.isEmpty == true)
        #expect(oldHydration.candidates.first?.state == .unknown)
        #expect(!oldHydration.authorizesSideEffects)
    }

    @Test("An old probe cannot hydrate a different canonical incarnation")
    func hydrationRequiresCanonicalIdentityMatch() async throws {
        let fixture = try MirrorFixture()
        let limits = try SceneMemoryLimits(maximumObjects: 1)
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let registration = try await fixture.register(store)
        let reusedKey = fixture.object()
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: reusedKey,
                    coordinateSpace: fixture.coordinateSpace,
                    label: "first canonical identity"
                ),
            ]),
            through: registration.handle
        )
        let oldProbe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        let oldCanonicalID = try #require(oldProbe.candidates.first?.spatial.canonicalID)

        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 2,
                    object: fixture.object(),
                    coordinateSpace: fixture.coordinateSpace,
                    label: "evicts first object"
                ),
            ]),
            through: registration.handle
        )
        #expect(await store.lookup(object: reusedKey) == nil)
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 3,
                    object: reusedKey,
                    coordinateSpace: fixture.coordinateSpace,
                    label: "new canonical identity"
                ),
            ]),
            through: registration.handle
        )
        let current = try #require(await store.lookup(object: reusedKey))
        #expect(current.canonicalID != oldCanonicalID)

        let hydrated = await mirror.hydrate(oldProbe, fields: [fixture.label])
        #expect(hydrated.candidates.first?.object == nil)
        #expect(hydrated.candidates.first?.state == .unknown)
        #expect(!hydrated.authorizesSideEffects)
    }

    @Test("Receiver-time policy expires geometry before stable label and role metadata")
    func receiverTimeReusePolicy() async throws {
        let fixture = try MirrorFixture()
        let initialTime: UInt64 = 10_000
        let clock = MirrorClock(initialTime)
        let hour: UInt64 = 3_600_000_000_000
        let policy = SceneMemoryReusePolicy(
            defaultWindow: try SceneMemoryReuseWindow(
                preferredAgeNs: 1_000_000_000,
                staleFallbackAgeNs: 5_000_000_000
            ),
            fieldWindows: [
                fixture.bounds: try SceneMemoryReuseWindow(
                    preferredAgeNs: 100_000_000,
                    staleFallbackAgeNs: 750_000_000
                ),
                fixture.label: try SceneMemoryReuseWindow(
                    preferredAgeNs: 300_000_000_000,
                    staleFallbackAgeNs: 4 * hour
                ),
                fixture.role: try SceneMemoryReuseWindow(
                    preferredAgeNs: hour,
                    staleFallbackAgeNs: 24 * hour
                ),
            ]
        )
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            reusePolicy: policy,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let event = try fixture.observation(
            sequence: 1,
            object: fixture.object(),
            coordinateSpace: fixture.coordinateSpace,
            label: "Stable label",
            role: "AXButton"
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [event]),
            through: registration.handle
        )
        let immediate = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        #expect(immediate.candidates.count == 1)

        clock.set(initialTime + hour)
        let agedGeometry = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        #expect(agedGeometry.candidates.isEmpty)
        #expect(agedGeometry.omittedExpiredGeometryCandidates == 1)
        #expect(!agedGeometry.isComplete)

        let firstPaint = await mirror.hydrate(
            immediate,
            fields: [fixture.bounds, fixture.label, fixture.role]
        )
        let candidate = try #require(firstPaint.candidates.first)
        #expect(candidate.omittedExpiredFields == [fixture.bounds])
        #expect(Set(candidate.fields.map(\.lookup.field)) == [fixture.label, fixture.role])
        #expect(candidate.fields.first(where: { $0.lookup.field == fixture.label })?.reuse ==
            .staleFallback)
        #expect(candidate.fields.first(where: { $0.lookup.field == fixture.label })?.lookup
            .freshness == .stale)
        #expect(candidate.fields.first(where: { $0.lookup.field == fixture.role })?.reuse ==
            .preferred)
    }

    @Test("Default cached geometry remains a non-actionable stale first paint at one hour")
    func defaultGeometryOneHourFallback() async throws {
        let fixture = try MirrorFixture()
        let initial: UInt64 = 5_000
        let hour: UInt64 = 3_600_000_000_000
        let clock = MirrorClock(initial)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: fixture.object(),
                    coordinateSpace: fixture.coordinateSpace,
                    label: "hour-old first paint"
                ),
            ]),
            through: registration.handle
        )

        clock.set(initial + hour)
        let probe = mirror.probe(
            at: try ScenePoint(x: 10, y: 10),
            in: fixture.coordinateSpace
        )
        #expect(probe.candidates.count == 1)
        #expect(probe.candidates.first?.state == .stale)
        #expect(probe.omittedExpiredGeometryCandidates == 0)
        #expect(probe.actionRequirement == .freshLiveAnchorRequired)
        #expect(!probe.authorizesSideEffects)
    }

    @Test("Concurrent synchronous readers never observe a regressing publication")
    func concurrentReadSafety() async throws {
        let fixture = try MirrorFixture()
        let clock = MirrorClock(1_000)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let mirror = SceneMemorySnapshotMirror(
            store: store,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store)
        let events = try (1 ... 32).map { sequence in
            try fixture.observation(
                sequence: UInt64(sequence),
                object: fixture.object(),
                coordinateSpace: fixture.coordinateSpace,
                label: "item-\(sequence)"
            )
        }
        let point = try ScenePoint(x: 10, y: 10)

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for event in events {
                    let receipt = await mirror.ingest(
                        try! SceneEventBatch(events: [event]),
                        through: registration.handle
                    )
                    if receipt.status == .rejected { return false }
                }
                return true
            }
            for _ in 0 ..< 12 {
                group.addTask {
                    var priorRevision: UInt64 = 0
                    for _ in 0 ..< 500 {
                        let probe = mirror.probe(
                            at: point,
                            in: fixture.coordinateSpace,
                            limit: 8
                        )
                        if probe.spatialSnapshotRevision < priorRevision ||
                            probe.candidates.count > 8 ||
                            probe.authorizesSideEffects
                        {
                            return false
                        }
                        priorRevision = probe.spatialSnapshotRevision
                    }
                    return true
                }
            }
            for await result in group {
                #expect(result)
            }
        }
        #expect(mirror.publishedSnapshotRevision > 0)
    }

    @Test("A cross-source dirty event marks dependent hot geometry stale")
    func dependencyStalenessReachesHotProbe() async throws {
        let session = SceneSessionID()
        let upstream = try MirrorFixture(session: session)
        let owner = try MirrorFixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let upstreamRegistration = try await upstream.register(store)
        let ownerRegistration = try await owner.register(
            store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let upstreamObject = upstream.object()
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: upstreamObject,
                    coordinateSpace: upstream.coordinateSpace,
                    label: "dirty sentinel"
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let ownerObject = owner.object()
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: ownerObject,
                    coordinateSpace: owner.coordinateSpace,
                    label: "dependent geometry",
                    geometryDependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: upstream.epoch,
                                sequence: 1
                            )
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        let point = try ScenePoint(x: 10, y: 10)
        let current = mirror.probe(at: point, in: owner.coordinateSpace)
        #expect(current.candidates.first?.state == .immediateCachedGeometry)
        #expect(current.candidates.first?.spatial.isDependencyStale == false)

        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try upstream.invalidation(
                    sequence: 2,
                    object: upstreamObject,
                    fields: [upstream.label],
                    reason: .contentDirty
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let stale = mirror.probe(at: point, in: owner.coordinateSpace)
        #expect(stale.candidates.first?.state == .stale)
        #expect(stale.candidates.first?.spatial.isDependencyStale == true)
        #expect(!stale.authorizesSideEffects)
    }

    @Test("Coverage-only revision changes rebuild when a hot dependency becomes stale")
    func coverageRevisionStalesHotDependency() async throws {
        let session = SceneSessionID()
        let upstream = try MirrorFixture(session: session)
        let owner = try MirrorFixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let upstreamRegistration = try await upstream.register(store)
        let ownerRegistration = try await owner.register(
            store,
            permittedDependencySources: [upstream.epoch.source]
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: upstream.object(),
                    coordinateSpace: upstream.coordinateSpace,
                    label: "dependency basis"
                ),
            ]),
            through: upstreamRegistration.handle
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: owner.object(),
                    coordinateSpace: owner.coordinateSpace,
                    label: "derived geometry",
                    geometryDependencies: [
                        SceneClaimDependency(
                            revision: try SourceRevision(
                                sourceEpoch: upstream.epoch,
                                sequence: 1
                            )
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        let point = try ScenePoint(x: 10, y: 10)
        let current = mirror.probe(at: point, in: owner.coordinateSpace)
        let revision = current.spatialSnapshotRevision
        #expect(current.candidates.first?.state == .immediateCachedGeometry)

        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try upstream.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let stale = mirror.probe(at: point, in: owner.coordinateSpace)
        #expect(stale.spatialSnapshotRevision > revision)
        #expect(stale.candidates.first?.state == .stale)
        #expect(stale.candidates.first?.spatial.isDependencyStale == true)
    }

    @Test("Internal region sentinels are addressable but never pointer candidates")
    func onlyCanonicalBoundsArePointerProbeable() async throws {
        let fixture = try MirrorFixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let registration = try await fixture.register(store)
        let object = fixture.object()
        let sentinel = try SceneFieldKey("screen.dirtyDisplayBounds")
        let region = SurfaceRegion(
            coordinateSpace: fixture.coordinateSpace,
            rect: try SceneRect(x: 0, y: 0, width: 100, height: 50)
        )
        let revision = try SourceRevision(sourceEpoch: fixture.epoch, sequence: 1)
        let observation = try SceneObservation(
            subject: object,
            observedAtSourceMonotonicNs: 1,
            claims: [
                try SceneFieldClaim(
                    field: sentinel,
                    value: .region(region),
                    knowledge: .observed,
                    confidence: 1,
                    sensitivity: .ordinary,
                    evidence: [
                        try SceneEvidence(
                            kind: .accessibility,
                            sourceRevision: revision
                        ),
                    ]
                ),
            ]
        )
        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try SceneEventEnvelope(
                    revision: revision,
                    emittedAtSourceMonotonicNs: 1,
                    payload: .observation(observation)
                ),
            ]),
            through: registration.handle
        )
        #expect(await store.lookup(object: object, fields: [sentinel])?.fields.first?.value ==
            .region(region))
        let point = try ScenePoint(x: 10, y: 10)
        #expect(mirror.probe(at: point, in: fixture.coordinateSpace).candidates.isEmpty)

        _ = await mirror.ingest(
            try SceneEventBatch(events: [
                try SceneEventEnvelope(
                    revision: SourceRevision(sourceEpoch: fixture.epoch, sequence: 2),
                    emittedAtSourceMonotonicNs: 2,
                    payload: .invalidation(
                        try SceneInvalidation(
                            scope: .region(region),
                            fields: [sentinel],
                            reason: .contentDirty,
                            observedAtSourceMonotonicNs: 2
                        )
                    )
                ),
            ]),
            through: registration.handle
        )
        #expect(await store.lookup(object: object, fields: [sentinel])?.fields.first?.freshness ==
            .stale)
        #expect(mirror.probe(at: point, in: fixture.coordinateSpace).candidates.isEmpty)
    }
}

@Suite("Scene memory source epoch replacement")
struct SceneMemorySourceReplacementTests {
    @Test("A new epoch retires the old registration without leaking source budget")
    func replacementRetiresOldRegistration() async throws {
        let fixture = try MirrorFixture()
        let limits = try SceneMemoryLimits(maximumRegisteredSources: 1)
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)
        let old = try await fixture.register(store)
        let nextFixture = try MirrorFixture(
            session: fixture.session,
            device: fixture.device,
            sourceID: fixture.epoch.source.source,
            surface: fixture.surface,
            coordinateSpaceID: fixture.coordinateSpace.coordinateSpaceID
        )

        let replacement = try await nextFixture.register(store)
        #expect(await store.statistics().registeredSources == 1)
        let event = try fixture.observation(
            sequence: 1,
            object: fixture.object(),
            coordinateSpace: fixture.coordinateSpace,
            label: "old"
        )
        let oldReceipt = await store.ingest(
            try SceneEventBatch(events: [event]),
            through: old.handle
        )
        #expect(oldReceipt.status == .rejected)
        #expect(oldReceipt.rejection == .unauthorizedSource || oldReceipt.rejection == .staleEpoch)

        let currentEvent = try nextFixture.observation(
            sequence: 1,
            object: nextFixture.object(),
            coordinateSpace: nextFixture.coordinateSpace,
            label: "current"
        )
        #expect(
            await store.ingest(
                try SceneEventBatch(events: [currentEvent]),
                through: replacement.handle
            ).status == .accepted
        )
    }
}

private final class MirrorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func now() -> UInt64 {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }

    func set(_ next: UInt64) {
        lock.lock()
        value = next
        lock.unlock()
    }
}

private struct MirrorFixture: Sendable {
    let session: SceneSessionID
    let device: DevicePrincipalID
    let epoch: SceneSourceEpoch
    let surface: SceneSurfaceIdentity
    let coordinateSpace: SurfaceCoordinateSpace
    let label: SceneFieldKey
    let bounds: SceneFieldKey
    let role: SceneFieldKey

    init(
        session: SceneSessionID = SceneSessionID(),
        device: DevicePrincipalID = DevicePrincipalID(),
        sourceID: SceneSourceID = SceneSourceID(),
        surface: SceneSurfaceIdentity? = nil,
        coordinateSpaceID: CoordinateSpaceID = CoordinateSpaceID()
    ) throws {
        self.session = session
        self.device = device
        self.epoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: sourceID)
        )
        self.surface = surface ?? SceneSurfaceIdentity(
            device: device,
            surfaceID: SceneSurfaceID()
        )
        self.coordinateSpace = try SurfaceCoordinateSpace(
            surface: self.surface,
            coordinateSpaceID: coordinateSpaceID,
            revision: 1
        )
        self.label = try SceneFieldKey("content.label")
        self.bounds = try SceneFieldKey("geometry.bounds")
        self.role = try SceneFieldKey("accessibility.role")
    }

    func object() -> SourceObjectKey {
        SourceObjectKey(sourceEpoch: epoch, objectID: SourceObjectID())
    }

    func register(
        _ store: SceneMemoryStore,
        permittedDependencySources: Set<SceneSourceIdentity> = []
    ) async throws -> RegisteredSceneSource {
        var capabilities: Set<SceneSourceCapability> = [
            .structuredHierarchy,
            .geometry,
            .text,
            .checkpoints,
            .coverageReporting,
        ]
        if !permittedDependencySources.isEmpty {
            capabilities.insert(.crossSourceDependencies)
        }
        let manifest = try SceneSourceManifest(
            sourceEpoch: epoch,
            sessionID: session,
            displayName: "Mirror fixture",
            kind: .syntheticTest,
            capabilities: Array(capabilities)
        )
        return try await store.register(
            manifest: manifest,
            authorization: SceneSourceGrantPolicy(
                capabilities: capabilities,
                eventKinds: Set(SceneEventKind.allCases),
                evidenceKinds: [.accessibility],
                fields: .all,
                surfaces: .ownDevice,
                permittedDependencySources: permittedDependencySources
            )
        )
    }

    func observation(
        sequence: UInt64,
        object: SourceObjectKey,
        coordinateSpace: SurfaceCoordinateSpace,
        label: String,
        role: String = "AXButton",
        geometryDependencies: [SceneClaimDependency] = []
    ) throws -> SceneEventEnvelope {
        let revision = try SourceRevision(sourceEpoch: epoch, sequence: sequence)
        let evidence = [try SceneEvidence(kind: .accessibility, sourceRevision: revision)]
        let claims = [
            try SceneFieldClaim(
                field: bounds,
                value: .region(
                    SurfaceRegion(
                        coordinateSpace: coordinateSpace,
                        rect: try SceneRect(x: 0, y: 0, width: 100, height: 50)
                    )
                ),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .ordinary,
                evidence: evidence,
                dependencies: geometryDependencies
            ),
            try SceneFieldClaim(
                field: self.label,
                value: .text(label),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .ordinary,
                evidence: evidence
            ),
            try SceneFieldClaim(
                field: self.role,
                value: .text(role),
                knowledge: .observed,
                confidence: 1,
                sensitivity: .ordinary,
                evidence: evidence
            ),
        ]
        let observation = try SceneObservation(
            subject: object,
            observedAtSourceMonotonicNs: sequence,
            claims: claims
        )
        return try SceneEventEnvelope(
            revision: revision,
            emittedAtSourceMonotonicNs: sequence,
            payload: .observation(observation)
        )
    }

    func invalidation(
        sequence: UInt64,
        object: SourceObjectKey,
        fields: [SceneFieldKey],
        reason: SceneInvalidationReason = .valueChanged
    ) throws -> SceneEventEnvelope {
        try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sequence,
            payload: .invalidation(
                try SceneInvalidation(
                    scope: .object(object),
                    fields: fields,
                    reason: reason,
                    observedAtSourceMonotonicNs: sequence
                )
            )
        )
    }

    func checkpoint(
        sequence: UInt64,
        observations: [SceneObservation]
    ) throws -> SceneEventEnvelope {
        try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sequence,
            payload: .checkpoint(try SceneCheckpoint(observations: observations))
        )
    }

    func coverage(
        sequence: UInt64,
        stream: CoverageStreamID,
        continuity: UInt64,
        state: CoverageReportState
    ) throws -> SceneEventEnvelope {
        let report = try CoverageReport(
            streamID: stream,
            scope: .sourceProjection(epoch),
            continuitySequence: continuity,
            state: state,
            guarantee: .bestEffort,
            observedAtSourceMonotonicNs: sequence
        )
        return try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sequence,
            payload: .coverage(report)
        )
    }
}
