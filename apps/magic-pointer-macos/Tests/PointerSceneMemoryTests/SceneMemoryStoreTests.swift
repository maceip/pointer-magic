import Foundation
import PointerSceneContracts
import PointerSceneMemory
import Testing

@Suite("Scene memory registration and atomic ingestion")
struct SceneMemoryIngestionTests {
    @Test("An unauthorized surface rejects the whole batch")
    func unauthorizedSurfaceIsAtomic() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(1_000)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let firstObject = fixture.object()
        let secondObject = fixture.object()
        let first = try fixture.observation(
            sequence: 1,
            object: firstObject,
            claims: [ClaimSpec(fixture.label, .text("allowed"))]
        )
        let foreignSpace = try SurfaceCoordinateSpace(
            surface: SceneSurfaceIdentity(
                device: DevicePrincipalID(),
                surfaceID: SceneSurfaceID()
            ),
            coordinateSpaceID: CoordinateSpaceID(),
            revision: 1
        )
        let foreignRegion = SurfaceRegion(
            coordinateSpace: foreignSpace,
            rect: try SceneRect(x: 0, y: 0, width: 20, height: 20)
        )
        let second = try fixture.observation(
            sequence: 2,
            object: secondObject,
            claims: [ClaimSpec(fixture.bounds, .region(foreignRegion))]
        )

        let rejected = await store.ingest(
            try SceneEventBatch(events: [first, second]),
            through: registration.handle
        )
        #expect(rejected.status == .rejected)
        #expect(rejected.rejection == .unauthorizedSurface)
        #expect(await store.statistics().objects == 0)

        let accepted = await store.ingest(
            try SceneEventBatch(events: [first]),
            through: registration.handle
        )
        #expect(accepted.status == .accepted)
        #expect(await store.lookup(object: firstObject)?.fields.first?.value == .text("allowed"))
    }

    @Test("Grant expiry and source handles are receiver enforced")
    func expiryAndHandleValidation() async throws {
        let fixture = try Fixture()
        let other = try Fixture(session: fixture.session)
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let expiring = try await fixture.register(store: store, expiry: 110)
        let otherRegistration = try await other.register(store: store)
        let event = try fixture.observation(
            sequence: 1,
            object: fixture.object(),
            claims: [ClaimSpec(fixture.label, .text("secret"))]
        )
        let batch = try SceneEventBatch(events: [event])

        let wrongHandle = await store.ingest(batch, through: otherRegistration.handle)
        #expect(wrongHandle.status == .rejected)
        #expect(wrongHandle.rejection == .unauthorizedSource)

        clock.set(110)
        let expired = await store.ingest(batch, through: expiring.handle)
        #expect(expired.status == .rejected)
        #expect(expired.rejection == .expiredGrant)
        #expect(await store.statistics().objects == 0)
    }

    @Test("Cross-batch replay is idempotent and equivocation is rejected")
    func replayAndEquivocation() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let first = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("first"))]
        )

        let initial = await store.ingest(
            try SceneEventBatch(events: [first]),
            through: registration.handle
        )
        #expect(initial.status == .accepted)
        let snapshotRevision = await store.spatialSnapshot().revision

        let replay = await store.ingest(
            try SceneEventBatch(events: [first]),
            through: registration.handle
        )
        #expect(replay.status == .accepted)
        #expect(replay.identicalReplays == [first.revision])
        #expect(await store.statistics().objects == 1)
        #expect(await store.spatialSnapshot().revision == snapshotRevision)

        let equivocation = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("different"))]
        )
        let rejected = await store.ingest(
            try SceneEventBatch(events: [equivocation]),
            through: registration.handle
        )
        #expect(rejected.status == .rejected)
        #expect(rejected.rejection == .sequenceEquivocation)
        #expect(await store.lookup(object: object)?.fields.first?.value == .text("first"))
    }

    @Test("The store enforces field and event authority before reduction")
    func fieldAndEventAuthority() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let capabilities: Set<SceneSourceCapability> = [.structuredHierarchy]
        let manifest = try SceneSourceManifest(
            sourceEpoch: fixture.epoch,
            sessionID: fixture.session,
            displayName: "Limited fixture",
            kind: .syntheticTest,
            capabilities: Array(capabilities)
        )
        let registration = try await store.register(
            manifest: manifest,
            authorization: SceneSourceGrantPolicy(
                capabilities: capabilities,
                eventKinds: [.observation],
                evidenceKinds: [.accessibility],
                fields: .listed([fixture.label]),
                surfaces: .ownDevice
            )
        )
        let denied = try fixture.observation(
            sequence: 1,
            object: fixture.object(),
            claims: [ClaimSpec(fixture.bounds, .boolean(true))]
        )
        let deniedField = await store.ingest(
            try SceneEventBatch(events: [denied]),
            through: registration.handle
        )
        #expect(deniedField.status == .rejected)
        #expect(deniedField.rejection == .unauthorizedCapability)

        let deniedCheckpoint = try fixture.checkpoint(sequence: 1, observations: [])
        let deniedEvent = await store.ingest(
            try SceneEventBatch(events: [deniedCheckpoint]),
            through: registration.handle
        )
        #expect(deniedEvent.status == .rejected)
        #expect(deniedEvent.rejection == .unauthorizedCapability)
        #expect(await store.statistics().objects == 0)
    }
}

@Suite("Cross-source dependency authority and freshness")
struct SceneMemoryDependencyTests {
    @Test("A dependency source allowlist is receiver-issued and batch-atomic")
    func dependencyAuthorityIsAtomic() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let deniedSource = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let upstreamRegistration = try await upstream.register(store: store)
        let deniedRegistration = try await deniedSource.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let upstreamObject = upstream.object()
        let deniedObject = deniedSource.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: upstreamObject,
                    claims: [ClaimSpec(upstream.label, .text("upstream"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try deniedSource.observation(
                    sequence: 1,
                    object: deniedObject,
                    claims: [ClaimSpec(deniedSource.label, .text("denied"))]
                ),
            ]),
            through: deniedRegistration.handle
        )

        let acceptedObject = owner.object()
        let deniedDerivedObject = owner.object()
        let authorized = try owner.observation(
            sequence: 1,
            object: acceptedObject,
            claims: [
                ClaimSpec(
                    owner.label,
                    .text("authorized"),
                    dependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: upstream.epoch,
                                sequence: 1
                            ),
                            object: upstreamObject,
                            field: upstream.label
                        ),
                    ]
                ),
            ]
        )
        let denied = try owner.observation(
            sequence: 2,
            object: deniedDerivedObject,
            claims: [
                ClaimSpec(
                    owner.label,
                    .text("must not land"),
                    dependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: deniedSource.epoch,
                                sequence: 1
                            ),
                            object: deniedObject,
                            field: deniedSource.label
                        ),
                    ]
                ),
            ]
        )

        let rejected = await store.ingest(
            try SceneEventBatch(events: [authorized, denied]),
            through: ownerRegistration.handle
        )
        #expect(rejected.status == .rejected)
        #expect(rejected.rejection == .unauthorizedCapability)
        #expect(await store.lookup(object: acceptedObject) == nil)
        #expect(await store.lookup(object: deniedDerivedObject) == nil)

        let accepted = await store.ingest(
            try SceneEventBatch(events: [authorized]),
            through: ownerRegistration.handle
        )
        #expect(accepted.status == .accepted)
        #expect(await freshness(store, acceptedObject, owner.label) == .provisional)
    }

    @Test("A field dependency stales only when its referenced field advances")
    func fieldDependencyTracksReferencedField() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let upstreamRegistration = try await upstream.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let upstreamObject = upstream.object()
        let derivedObject = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: upstreamObject,
                    claims: [ClaimSpec(upstream.label, .text("basis"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: derivedObject,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: upstream.epoch,
                                        sequence: 1
                                    ),
                                    object: upstreamObject,
                                    field: upstream.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await freshness(store, derivedObject, owner.label) == .provisional)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 2,
                    object: upstreamObject,
                    claims: [ClaimSpec(upstream.bounds, .boolean(true))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        #expect(await freshness(store, derivedObject, owner.label) == .provisional)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 3,
                    object: upstreamObject,
                    claims: [ClaimSpec(upstream.label, .text("advanced"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        #expect(await freshness(store, derivedObject, owner.label) == .stale)
    }

    @Test("Object tombstones and later source events stale scoped dependencies")
    func objectAndRevisionDependenciesStale() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let upstreamRegistration = try await upstream.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let objectTarget = upstream.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: objectTarget,
                    claims: [ClaimSpec(upstream.label, .text("object basis"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let objectDerived = owner.object()
        let revisionDerived = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: objectDerived,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("object derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: upstream.epoch,
                                        sequence: 1
                                    ),
                                    object: objectTarget
                                ),
                            ]
                        ),
                    ]
                ),
                try owner.observation(
                    sequence: 2,
                    object: revisionDerived,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("revision derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: upstream.epoch,
                                        sequence: 1
                                    )
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await freshness(store, objectDerived, owner.label) == .provisional)
        #expect(await freshness(store, revisionDerived, owner.label) == .provisional)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.invalidation(
                    sequence: 2,
                    scope: .object(objectTarget),
                    fields: [],
                    reason: .destroyed
                ),
            ]),
            through: upstreamRegistration.handle
        )
        #expect(await freshness(store, objectDerived, owner.label) == .stale)
        #expect(await freshness(store, revisionDerived, owner.label) == .stale)
    }

    @Test("Closing or restarting a referenced source stales its old epoch")
    func sourceLifecycleStalesDependencies() async throws {
        let session = SceneSessionID()
        let closingSource = try Fixture(session: session)
        let restartingSource = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let closingRegistration = try await closingSource.register(store: store)
        let restartingRegistration = try await restartingSource.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [
                closingSource.epoch.source,
                restartingSource.epoch.source,
            ]
        )
        let closingTarget = closingSource.object()
        let restartingTarget = restartingSource.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try closingSource.observation(
                    sequence: 1,
                    object: closingTarget,
                    claims: [ClaimSpec(closingSource.label, .text("close"))]
                ),
            ]),
            through: closingRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try restartingSource.observation(
                    sequence: 1,
                    object: restartingTarget,
                    claims: [ClaimSpec(restartingSource.label, .text("restart"))]
                ),
            ]),
            through: restartingRegistration.handle
        )
        let closeDerived = owner.object()
        let restartDerived = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: closeDerived,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("close derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: closingSource.epoch,
                                        sequence: 1
                                    ),
                                    object: closingTarget,
                                    field: closingSource.label
                                ),
                            ]
                        ),
                    ]
                ),
                try owner.observation(
                    sequence: 2,
                    object: restartDerived,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("restart derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: restartingSource.epoch,
                                        sequence: 1
                                    ),
                                    object: restartingTarget,
                                    field: restartingSource.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await freshness(store, closeDerived, owner.label) == .provisional)
        #expect(await freshness(store, restartDerived, owner.label) == .provisional)

        #expect(await store.closeSource(closingRegistration.handle))
        #expect(await freshness(store, closeDerived, owner.label) == .stale)
        #expect(await freshness(store, restartDerived, owner.label) == .provisional)

        let restarted = try Fixture(
            session: session,
            device: restartingSource.device,
            sourceID: restartingSource.sourceID
        )
        _ = try await restarted.register(store: store)
        #expect(await freshness(store, restartDerived, owner.label) == .stale)
    }

    @Test("Dependency staleness traverses chains and fails stale on cycles")
    func transitiveAndCyclicDependencies() async throws {
        let session = SceneSessionID()
        let root = try Fixture(session: session)
        let middle = try Fixture(session: session)
        let leaf = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let rootRegistration = try await root.register(store: store)
        let middleRegistration = try await middle.register(
            store: store,
            permittedDependencySources: [root.epoch.source]
        )
        let leafRegistration = try await leaf.register(
            store: store,
            permittedDependencySources: [middle.epoch.source]
        )
        let rootObject = root.object()
        let middleObject = middle.object()
        let leafObject = leaf.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 1,
                    object: rootObject,
                    claims: [ClaimSpec(root.label, .text("root"))]
                ),
            ]),
            through: rootRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try middle.observation(
                    sequence: 1,
                    object: middleObject,
                    claims: [
                        ClaimSpec(
                            middle.label,
                            .text("middle"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: root.epoch,
                                        sequence: 1
                                    ),
                                    object: rootObject,
                                    field: root.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: middleRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try leaf.observation(
                    sequence: 1,
                    object: leafObject,
                    claims: [
                        ClaimSpec(
                            leaf.label,
                            .text("leaf"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: middle.epoch,
                                        sequence: 1
                                    ),
                                    object: middleObject,
                                    field: middle.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: leafRegistration.handle
        )
        #expect(await freshness(store, leafObject, leaf.label) == .provisional)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 2,
                    object: rootObject,
                    claims: [ClaimSpec(root.label, .text("advanced"))]
                ),
            ]),
            through: rootRegistration.handle
        )
        #expect(await freshness(store, middleObject, middle.label) == .stale)
        #expect(await freshness(store, leafObject, leaf.label) == .stale)

        let cycle = try Fixture(session: session)
        let cycleRegistration = try await cycle.register(store: store)
        let first = cycle.object()
        let second = cycle.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try cycle.observation(
                    sequence: 1,
                    object: first,
                    claims: [
                        ClaimSpec(
                            cycle.label,
                            .text("first"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: cycle.epoch,
                                        sequence: 2
                                    ),
                                    object: second,
                                    field: cycle.label
                                ),
                            ]
                        ),
                    ]
                ),
                try cycle.observation(
                    sequence: 2,
                    object: second,
                    claims: [
                        ClaimSpec(
                            cycle.label,
                            .text("second"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: cycle.epoch,
                                        sequence: 1
                                    ),
                                    object: first,
                                    field: cycle.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: cycleRegistration.handle
        )
        #expect(await freshness(store, first, cycle.label) == .stale)
        #expect(await freshness(store, second, cycle.label) == .stale)
    }

    @Test("A privacy boundary withholds transitive cross-source derived values")
    func privacyBoundaryPurgesDerivedValues() async throws {
        let session = SceneSessionID()
        let root = try Fixture(session: session)
        let middle = try Fixture(session: session)
        let leaf = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let rootRegistration = try await root.register(store: store)
        let middleRegistration = try await middle.register(
            store: store,
            permittedDependencySources: [root.epoch.source]
        )
        let leafRegistration = try await leaf.register(
            store: store,
            permittedDependencySources: [middle.epoch.source]
        )
        let rootObject = root.object()
        let middleObject = middle.object()
        let leafObject = leaf.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 1,
                    object: rootObject,
                    claims: [ClaimSpec(root.label, .text("private basis"))]
                ),
            ]),
            through: rootRegistration.handle
        )
        let middleEvent = try middle.observation(
            sequence: 1,
            object: middleObject,
            claims: [
                ClaimSpec(
                    middle.label,
                    .text("derived private value"),
                    dependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: root.epoch,
                                sequence: 1
                            ),
                            object: rootObject,
                            field: root.label
                        ),
                    ]
                ),
            ]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [middleEvent]),
            through: middleRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try leaf.observation(
                    sequence: 1,
                    object: leafObject,
                    claims: [
                        ClaimSpec(
                            leaf.label,
                            .text("transitively private value"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: middle.epoch,
                                        sequence: 1
                                    ),
                                    object: middleObject,
                                    field: middle.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: leafRegistration.handle
        )
        #expect(await store.lookup(object: middleObject)?.fields.first?.value != nil)
        #expect(await store.lookup(object: leafObject)?.fields.first?.value != nil)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.invalidation(
                    sequence: 2,
                    scope: .object(rootObject),
                    fields: [root.label],
                    reason: .privacyBoundary
                ),
            ]),
            through: rootRegistration.handle
        )
        #expect(await store.lookup(object: middleObject)?.fields.first?.value == nil)
        #expect(await store.lookup(object: leafObject)?.fields.first?.value == nil)
        #expect(await freshness(store, middleObject, middle.label) == .stale)
        #expect(await freshness(store, leafObject, leaf.label) == .stale)

        let replay = await store.ingest(
            try SceneEventBatch(events: [middleEvent]),
            through: middleRegistration.handle
        )
        #expect(replay.status == .rejected)
        #expect(replay.rejection == .invalidBatch)

        let laterDerivedObject = middle.object()
        let laterDerived = try middle.observation(
            sequence: 2,
            object: laterDerivedObject,
            claims: [
                ClaimSpec(
                    middle.label,
                    .text("must also be withheld"),
                    dependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: root.epoch,
                                sequence: 1
                            ),
                            object: rootObject,
                            field: root.label
                        ),
                    ]
                ),
            ]
        )
        #expect(
            await store.ingest(
                try SceneEventBatch(events: [laterDerived]),
                through: middleRegistration.handle
            ).status == .accepted
        )
        #expect(await store.lookup(object: laterDerivedObject)?.fields.first?.value == nil)
    }

    @Test("Secure and unknown dependencies withhold direct and transitive derived values")
    func secureAndUnknownPrivacyIsTransitive() async throws {
        let session = SceneSessionID()
        let root = try Fixture(session: session)
        let middle = try Fixture(session: session)
        let leaf = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let rootRegistration = try await root.register(store: store)
        let middleRegistration = try await middle.register(
            store: store,
            permittedDependencySources: [root.epoch.source]
        )
        let leafRegistration = try await leaf.register(
            store: store,
            permittedDependencySources: [middle.epoch.source]
        )
        let secureRoot = root.object()
        let unknownRoot = root.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 1,
                    object: secureRoot,
                    claims: [ClaimSpec(root.label, nil, sensitivity: .secure)]
                ),
                try root.observation(
                    sequence: 2,
                    object: unknownRoot,
                    claims: [ClaimSpec(root.label, nil, sensitivity: .unknown)]
                ),
            ]),
            through: rootRegistration.handle
        )

        let directSecure = middle.object()
        let directUnknown = middle.object()
        let middleEvents = [
            try middle.observation(
                sequence: 1,
                object: directSecure,
                claims: [
                    ClaimSpec(
                        middle.label,
                        .text("must withhold secure derivation"),
                        dependencies: [
                            SceneClaimDependency(
                                revision: SourceRevision(
                                    sourceEpoch: root.epoch,
                                    sequence: 1
                                ),
                                object: secureRoot,
                                field: root.label
                            ),
                        ]
                    ),
                ]
            ),
            try middle.observation(
                sequence: 2,
                object: directUnknown,
                claims: [
                    ClaimSpec(
                        middle.label,
                        .text("must withhold unknown derivation"),
                        dependencies: [
                            SceneClaimDependency(
                                revision: SourceRevision(
                                    sourceEpoch: root.epoch,
                                    sequence: 2
                                ),
                                object: unknownRoot,
                                field: root.label
                            ),
                        ]
                    ),
                ]
            ),
        ]
        _ = await store.ingest(
            try SceneEventBatch(events: middleEvents),
            through: middleRegistration.handle
        )

        let transitiveSecure = leaf.object()
        let transitiveUnknown = leaf.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try leaf.observation(
                    sequence: 1,
                    object: transitiveSecure,
                    claims: [
                        ClaimSpec(
                            leaf.label,
                            .text("must withhold transitive secure derivation"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: middle.epoch,
                                        sequence: 1
                                    ),
                                    object: directSecure,
                                    field: middle.label
                                ),
                            ]
                        ),
                    ]
                ),
                try leaf.observation(
                    sequence: 2,
                    object: transitiveUnknown,
                    claims: [
                        ClaimSpec(
                            leaf.label,
                            .text("must withhold transitive unknown derivation"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: middle.epoch,
                                        sequence: 2
                                    ),
                                    object: directUnknown,
                                    field: middle.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: leafRegistration.handle
        )

        for object in [directSecure, directUnknown, transitiveSecure, transitiveUnknown] {
            #expect(await store.lookup(object: object)?.fields.first?.value == nil)
        }
        let replay = await store.ingest(
            try SceneEventBatch(events: [middleEvents[0]]),
            through: middleRegistration.handle
        )
        #expect(replay.rejection == .invalidBatch)
    }

    @Test("An observation privacy reclassification purges older replay bytes")
    func observationPrivacyReclassificationPurgesReplay() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let ordinary = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("formerly ordinary"))]
        )
        #expect(
            await store.ingest(
                try SceneEventBatch(events: [ordinary]),
                through: registration.handle
            ).status == .accepted
        )
        let secure = try fixture.observation(
            sequence: 2,
            object: object,
            claims: [ClaimSpec(fixture.label, nil, sensitivity: .secure)]
        )
        #expect(
            await store.ingest(
                try SceneEventBatch(events: [secure]),
                through: registration.handle
            ).status == .accepted
        )

        let field = await store.lookup(object: object, fields: [fixture.label])?.fields.first
        #expect(field?.value == nil)
        #expect(field?.sensitivity == .secure)
        let oldReplay = await store.ingest(
            try SceneEventBatch(events: [ordinary]),
            through: registration.handle
        )
        #expect(oldReplay.status == .rejected)
        #expect(oldReplay.rejection == .invalidBatch)
    }

    @Test("A checkpoint privacy reclassification purges older replay bytes")
    func checkpointPrivacyReclassificationPurgesReplay() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let ordinary = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("formerly ordinary"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [ordinary]),
            through: registration.handle
        )
        let secureBaseline = try fixture.sceneObservation(
            sequence: 2,
            object: object,
            claims: [ClaimSpec(fixture.label, nil, sensitivity: .unknown)]
        )
        #expect(
            await store.ingest(
                try SceneEventBatch(events: [
                    try fixture.checkpoint(
                        sequence: 2,
                        observations: [secureBaseline]
                    ),
                ]),
                through: registration.handle
            ).status == .accepted
        )

        let field = await store.lookup(object: object, fields: [fixture.label])?.fields.first
        #expect(field?.value == nil)
        #expect(field?.sensitivity == .unknown)
        let oldReplay = await store.ingest(
            try SceneEventBatch(events: [ordinary]),
            through: registration.handle
        )
        #expect(oldReplay.status == .rejected)
        #expect(oldReplay.rejection == .invalidBatch)
    }

    @Test("A spatial privacy boundary covers matching objects evicted from memory")
    func spatialPrivacyBoundaryPromotesProjectionFloor() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let downstream = try Fixture(session: session)
        let limits = try SceneMemoryLimits(maximumObjects: 2)
        let store = SceneMemoryStore(sessionID: session, limits: limits)
        let upstreamRegistration = try await upstream.register(store: store)
        let downstreamRegistration = try await downstream.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let privateObject = upstream.object()
        let visibleMatch = upstream.object()
        let pressure = upstream.object()
        let privateRegion = SurfaceRegion(
            coordinateSpace: upstream.space,
            rect: try SceneRect(x: 400, y: 400, width: 20, height: 20)
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: privateObject,
                    claims: [
                        ClaimSpec(upstream.label, .text("old private bytes")),
                        ClaimSpec(upstream.bounds, .region(privateRegion)),
                    ]
                ),
                try upstream.observation(
                    sequence: 2,
                    object: visibleMatch,
                    claims: [
                        ClaimSpec(upstream.label, .text("current match")),
                        ClaimSpec(upstream.bounds, .region(privateRegion)),
                    ]
                ),
                try upstream.observation(
                    sequence: 3,
                    object: pressure,
                    claims: [ClaimSpec(upstream.label, .text("eviction pressure"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        #expect(await store.lookup(object: privateObject) == nil)
        #expect(await store.lookup(object: visibleMatch) != nil)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.invalidation(
                    sequence: 4,
                    scope: .region(privateRegion),
                    fields: [upstream.label],
                    reason: .privacyBoundary
                ),
            ]),
            through: upstreamRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 5,
                    object: privateObject,
                    claims: [ClaimSpec(upstream.label, .text("ordinary reappearance"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )

        let derivedObject = downstream.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try downstream.observation(
                    sequence: 1,
                    object: derivedObject,
                    claims: [
                        ClaimSpec(
                            downstream.label,
                            .text("must not survive"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: upstream.epoch,
                                        sequence: 1
                                    ),
                                    object: privateObject,
                                    field: upstream.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: downstreamRegistration.handle
        )
        #expect(
            await store.lookup(
                object: derivedObject,
                fields: [downstream.label]
            )?.fields.first?.value == nil
        )
    }

    @Test("Eviction purges replay bytes for an absent derived object")
    func evictionPurgesAbsentDerivedReplay() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let downstream = try Fixture(session: session)
        let limits = try SceneMemoryLimits(maximumObjects: 2)
        let store = SceneMemoryStore(sessionID: session, limits: limits)
        let upstreamRegistration = try await upstream.register(store: store)
        let downstreamRegistration = try await downstream.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let basis = upstream.object()
        let derived = downstream.object()
        let pressure = upstream.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: basis,
                    claims: [ClaimSpec(upstream.label, .text("ordinary basis"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let derivedEvent = try downstream.observation(
            sequence: 1,
            object: derived,
            claims: [
                ClaimSpec(
                    downstream.label,
                    .text("derived private bytes"),
                    dependencies: [
                        SceneClaimDependency(
                            revision: SourceRevision(
                                sourceEpoch: upstream.epoch,
                                sequence: 1
                            ),
                            object: basis,
                            field: upstream.label
                        ),
                    ]
                ),
            ]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [derivedEvent]),
            through: downstreamRegistration.handle
        )
        #expect(await store.lookup(object: derived)?.fields.first?.value != nil)

        // Touch the basis after the derived object so deterministic pressure
        // evicts the derived object first.
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 2,
                    object: basis,
                    claims: [ClaimSpec(upstream.label, .text("updated basis"))]
                ),
                try upstream.observation(
                    sequence: 3,
                    object: pressure,
                    claims: [ClaimSpec(upstream.label, .text("pressure"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        #expect(await store.lookup(object: derived) == nil)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 4,
                    object: basis,
                    claims: [ClaimSpec(upstream.label, nil, sensitivity: .secure)]
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let oldReplay = await store.ingest(
            try SceneEventBatch(events: [derivedEvent]),
            through: downstreamRegistration.handle
        )
        #expect(oldReplay.status == .rejected)
        #expect(oldReplay.rejection == .invalidBatch)
    }

    @Test("Missing exact dependency projections, objects, and fields fail closed")
    func missingPrivacyDependenciesFailClosed() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let missing = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let upstreamRegistration = try await upstream.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [
                upstream.epoch.source,
                missing.epoch.source,
            ]
        )
        let existingObject = upstream.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: existingObject,
                    claims: [ClaimSpec(upstream.label, .text("ordinary"))]
                ),
            ]),
            through: upstreamRegistration.handle
        )

        let missingObject = upstream.object()
        let missingField = try SceneFieldKey("content.missing")
        let derivedObjects = [owner.object(), owner.object(), owner.object()]
        let dependencies = [
            SceneClaimDependency(
                revision: try SourceRevision(sourceEpoch: missing.epoch, sequence: 1),
                object: missing.object(),
                field: missing.label
            ),
            SceneClaimDependency(
                revision: try SourceRevision(sourceEpoch: upstream.epoch, sequence: 1),
                object: missingObject,
                field: upstream.label
            ),
            SceneClaimDependency(
                revision: try SourceRevision(sourceEpoch: upstream.epoch, sequence: 1),
                object: existingObject,
                field: missingField
            ),
        ]
        let events = try zip(derivedObjects, dependencies).enumerated().map {
            index, pair in
            try owner.observation(
                sequence: UInt64(index + 1),
                object: pair.0,
                claims: [
                    ClaimSpec(
                        owner.label,
                        .text("must fail closed"),
                        dependencies: [pair.1]
                    ),
                ]
            )
        }
        #expect(
            await store.ingest(
                try SceneEventBatch(events: events),
                through: ownerRegistration.handle
            ).status == .accepted
        )
        for object in derivedObjects {
            #expect(await store.lookup(object: object)?.fields.first?.value == nil)
        }
    }

    @Test("A scoped privacy floor survives ordinary reobservation")
    func privacyFloorSurvivesReobservation() async throws {
        let session = SceneSessionID()
        let root = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let rootRegistration = try await root.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [root.epoch.source]
        )
        let rootObject = root.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 1,
                    object: rootObject,
                    claims: [ClaimSpec(root.label, .text("pre-boundary"))]
                ),
                try root.invalidation(
                    sequence: 2,
                    scope: .object(rootObject),
                    fields: [root.label],
                    reason: .privacyBoundary
                ),
                try root.observation(
                    sequence: 3,
                    object: rootObject,
                    claims: [ClaimSpec(root.label, .text("post-boundary ordinary"))]
                ),
            ]),
            through: rootRegistration.handle
        )
        #expect(
            await store.lookup(object: rootObject, fields: [root.label])?.fields.first?.value ==
                .text("post-boundary ordinary")
        )

        let lateOldDerivation = owner.object()
        let postBoundaryDerivation = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: lateOldDerivation,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("must stay withheld"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: root.epoch,
                                        sequence: 1
                                    ),
                                    object: rootObject,
                                    field: root.label
                                ),
                            ]
                        ),
                    ]
                ),
                try owner.observation(
                    sequence: 2,
                    object: postBoundaryDerivation,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("allowed new derivation"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: root.epoch,
                                        sequence: 3
                                    ),
                                    object: rootObject,
                                    field: root.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await store.lookup(object: lateOldDerivation)?.fields.first?.value == nil)
        #expect(
            await store.lookup(object: postBoundaryDerivation)?.fields.first?.value ==
                .text("allowed new derivation")
        )
    }

    @Test("Scoped privacy floors compact to a bounded fail-closed projection floor")
    func privacyFloorsAreBounded() async throws {
        let session = SceneSessionID()
        let root = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let limits = try SceneMemoryLimits(maximumPrivacyRevisionFloorsPerSource: 2)
        let store = SceneMemoryStore(sessionID: session, limits: limits)
        let rootRegistration = try await root.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [root.epoch.source]
        )
        let roots = [root.object(), root.object(), root.object()]
        let secureEvents = try roots.enumerated().map { index, object in
            try root.observation(
                sequence: UInt64(index + 1),
                object: object,
                claims: [ClaimSpec(root.label, nil, sensitivity: .secure)]
            )
        }
        _ = await store.ingest(
            try SceneEventBatch(events: secureEvents),
            through: rootRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try root.observation(
                    sequence: 4,
                    object: roots[0],
                    claims: [ClaimSpec(root.label, .text("ordinary again"))]
                ),
            ]),
            through: rootRegistration.handle
        )

        let derived = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.observation(
                    sequence: 1,
                    object: derived,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("must remain withheld"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: root.epoch,
                                        sequence: 1
                                    ),
                                    object: roots[0],
                                    field: root.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await store.lookup(object: derived)?.fields.first?.value == nil)
        #expect(await store.statistics().privacyRevisionFloors == 2)
    }

    @Test("Complete owner coverage cannot elevate a best-effort dependency")
    func dependencyTrustCapsVerifiedFreshness() async throws {
        let session = SceneSessionID()
        let upstream = try Fixture(session: session)
        let owner = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let upstreamRegistration = try await upstream.register(store: store)
        let ownerRegistration = try await owner.register(
            store: store,
            permittedDependencySources: [upstream.epoch.source]
        )
        let upstreamObject = upstream.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try upstream.observation(
                    sequence: 1,
                    object: upstreamObject,
                    claims: [ClaimSpec(upstream.label, .text("best effort"))]
                ),
                try upstream.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    scope: .object(upstreamObject),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000),
                    guarantee: .bestEffort
                ),
            ]),
            through: upstreamRegistration.handle
        )
        let ownerObject = owner.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try owner.checkpoint(sequence: 1, observations: []),
                try owner.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    scope: .object(ownerObject),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
                try owner.observation(
                    sequence: 3,
                    object: ownerObject,
                    claims: [
                        ClaimSpec(
                            owner.label,
                            .text("owner covered"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: SourceRevision(
                                        sourceEpoch: upstream.epoch,
                                        sequence: 1
                                    ),
                                    object: upstreamObject,
                                    field: upstream.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: ownerRegistration.handle
        )
        #expect(await freshness(store, ownerObject, owner.label) == .provisional)
    }

    @Test("Retirement bookkeeping fails closed at its explicit bound")
    func retiredEpochsAreBounded() async throws {
        let session = SceneSessionID()
        let initial = try Fixture(session: session)
        let limits = try SceneMemoryLimits(
            maximumRegisteredSources: 1,
            maximumRetiredSourceEpochs: 3
        )
        let store = SceneMemoryStore(sessionID: session, limits: limits)
        var current = try await initial.register(store: store)
        for _ in 0 ..< 3 {
            let replacement = try Fixture(
                session: session,
                device: initial.device,
                sourceID: initial.sourceID
            )
            current = try await replacement.register(store: store)
        }
        #expect(await store.statistics().sourceProjections == 4)

        let blocked = try Fixture(
            session: session,
            device: initial.device,
            sourceID: initial.sourceID
        )
        do {
            _ = try await blocked.register(store: store)
            Issue.record("registration must fail closed after retirement capacity")
        } catch let error as SceneSourceRegistrationError {
            #expect(error == .retirementCapacityExhausted)
        }

        #expect(await store.closeSource(current.handle))
        do {
            _ = try await initial.register(store: store)
            Issue.record("an old epoch must never regain authority")
        } catch let error as SceneSourceRegistrationError {
            #expect(error == .retirementCapacityExhausted)
        }
        #expect(await store.statistics().sourceProjections == 4)
    }
}

@Suite("Scene memory coverage and freshness")
struct SceneMemoryFreshnessTests {
    @Test("Only complete unexpired receiver-time coverage verifies a field")
    func coverageFreshnessUsesReceiverTime() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(1_000)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        let baseline = try fixture.checkpoint(sequence: 1, observations: [])
        let started = try fixture.coverage(
            sequence: 2,
            stream: stream,
            scope: .object(object),
            continuity: 1,
            state: .started(maximumSilenceNs: 100),
            sourceTime: UInt64.max - 10
        )
        let observed = try fixture.observation(
            sequence: 3,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("covered"))]
        )
        let receipt = await store.ingest(
            try SceneEventBatch(events: [baseline, started, observed]),
            through: registration.handle
        )
        #expect(receipt.status == .accepted)
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        let lease = await store.coverageLease(sourceEpoch: fixture.epoch, streamID: stream)
        #expect(lease?.receivedAtReceiverMonotonicNs == 1_000)
        #expect(lease?.expiresAtReceiverMonotonicNs == 1_100)

        clock.set(1_100)
        #expect(await freshness(store, object, fixture.label) == .provisional)
        #expect(
            await store.coverageLease(
                sourceEpoch: fixture.epoch,
                streamID: stream
            )?.state == .broken(.producerPaused)
        )
    }

    @Test(
        "A heartbeat at or after receiver expiry breaks continuity until a checkpoint",
        arguments: [UInt64(200), UInt64(201)]
    )
    func lateHeartbeatCannotRenewExpiredCoverage(arrival: UInt64) async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 1, observations: []),
                try fixture.coverage(
                    sequence: 2,
                    stream: stream,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 100)
                ),
                try fixture.observation(
                    sequence: 3,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("covered"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        clock.set(arrival)
        let late = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 4,
                    stream: stream,
                    scope: .object(object),
                    continuity: 2,
                    state: .heartbeat
                ),
            ]),
            through: registration.handle
        )
        #expect(late.status == .accepted)
        #expect(
            await store.coverageLease(sourceEpoch: fixture.epoch, streamID: stream)?.state ==
                .broken(.producerPaused)
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let replacement = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 5,
                    stream: replacement,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 100)
                ),
                try fixture.observation(
                    sequence: 6,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("not yet reverified"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let recoveryBaseline = try fixture.sceneObservation(
            sequence: 7,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("recovery baseline"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 7, observations: [recoveryBaseline]),
                try fixture.observation(
                    sequence: 8,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("reverified"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("A new complete stream cannot reuse a checkpoint across natural lease expiry")
    func naturalCoverageExpiryRequiresNewCheckpoint() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 1, observations: []),
                try fixture.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 10)
                ),
                try fixture.observation(
                    sequence: 3,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("initially verified"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        clock.set(110)
        let replacement = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 4,
                    stream: replacement,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 100)
                ),
                try fixture.observation(
                    sequence: 5,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("not resurrected"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        clock.set(111)
        let baseline = try fixture.sceneObservation(
            sequence: 6,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("fresh baseline"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 6, observations: [baseline]),
                try fixture.observation(
                    sequence: 7,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("verified after baseline"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("Coverage-record eviction cannot preserve an old complete baseline")
    func coverageEvictionRequiresNewCheckpoint() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let limits = try SceneMemoryLimits(maximumCoverageStreamsPerSource: 1)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            limits: limits,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 1, observations: []),
                try fixture.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
                try fixture.observation(
                    sequence: 3,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("verified"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        let replacement = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 4,
                    stream: replacement,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
                try fixture.observation(
                    sequence: 5,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("must be provisional"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let baseline = try fixture.sceneObservation(
            sequence: 6,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("replacement baseline"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 6, observations: [baseline]),
                try fixture.observation(
                    sequence: 7,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("verified again"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("Complete coverage waits for a checkpoint baseline")
    func completeCoverageRequiresBaseline() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        let started = try fixture.coverage(
            sequence: 1,
            stream: stream,
            scope: .object(object),
            continuity: 1,
            state: .started(maximumSilenceNs: 1_000)
        )
        let beforeBaseline = try fixture.observation(
            sequence: 2,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("unverified"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [started, beforeBaseline]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let checkpointObservation = try fixture.sceneObservation(
            sequence: 3,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("checkpoint baseline"))]
        )
        let checkpoint = try fixture.checkpoint(
            sequence: 3,
            observations: [checkpointObservation]
        )
        let afterBaseline = try fixture.observation(
            sequence: 4,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("verified"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [checkpoint, afterBaseline]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("Receiver silence cap and grant expiry bound freshness")
    func receiverBoundsCoverage() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let limits = try SceneMemoryLimits(maximumCoverageSilenceNs: 50)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            limits: limits,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store, expiry: 140)
        let object = fixture.object()
        let stream = CoverageStreamID()
        let events = [
            try fixture.checkpoint(sequence: 1, observations: []),
            try fixture.coverage(
                sequence: 2,
                stream: stream,
                scope: .object(object),
                continuity: 1,
                state: .started(maximumSilenceNs: 10_000)
            ),
            try fixture.observation(
                sequence: 3,
                object: object,
                claims: [ClaimSpec(fixture.label, .text("bounded"))]
            ),
        ]
        _ = await store.ingest(
            try SceneEventBatch(events: events),
            through: registration.handle
        )
        let lease = await store.coverageLease(sourceEpoch: fixture.epoch, streamID: stream)
        #expect(lease?.expiresAtReceiverMonotonicNs == 150)
        clock.set(139)
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
        clock.set(140)
        #expect(await freshness(store, object, fixture.label) == .provisional)
    }

    @Test("Closing a source breaks coverage and retires its epoch")
    func closeSourceBreaksCoverage() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        let events = [
            try fixture.checkpoint(sequence: 1, observations: []),
            try fixture.coverage(
                sequence: 2,
                stream: stream,
                scope: .object(object),
                continuity: 1,
                state: .started(maximumSilenceNs: 1_000)
            ),
            try fixture.observation(
                sequence: 3,
                object: object,
                claims: [ClaimSpec(fixture.label, .text("live"))]
            ),
        ]
        _ = await store.ingest(
            try SceneEventBatch(events: events),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
        #expect(await store.closeSource(registration.handle))
        #expect(await freshness(store, object, fixture.label) == .historical)
        #expect(
            await store.coverageLease(sourceEpoch: fixture.epoch, streamID: stream)?.state ==
                .broken(.disconnected)
        )

        let late = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 4,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("late"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(late.rejection == .unauthorizedSource)
    }

    @Test("A source sequence gap breaks coverage before later observations")
    func sourceGapBreaksCoverage() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(500)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        let baseline = try fixture.checkpoint(sequence: 1, observations: [])
        let started = try fixture.coverage(
            sequence: 2,
            stream: stream,
            scope: .object(object),
            continuity: 1,
            state: .started(maximumSilenceNs: 1_000)
        )
        let observed = try fixture.observation(
            sequence: 3,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("initial"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [baseline, started, observed]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        let afterGap = try fixture.observation(
            sequence: 5,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("after gap"))]
        )
        let receipt = await store.ingest(
            try SceneEventBatch(events: [afterGap]),
            through: registration.handle
        )
        #expect(receipt.status == .acceptedWithCoverageGap)
        #expect(receipt.sequenceGaps == [
            try SourceSequenceGap(
                sourceEpoch: fixture.epoch,
                missingFrom: 4,
                missingThrough: 4
            ),
        ])
        #expect(await freshness(store, object, fixture.label) == .provisional)
        #expect(
            await store.coverageLease(sourceEpoch: fixture.epoch, streamID: stream)?.state ==
                .broken(.sequenceGap)
        )

        let replacementStream = CoverageStreamID()
        let replacement = try fixture.coverage(
            sequence: 6,
            stream: replacementStream,
            scope: .object(object),
            continuity: 1,
            state: .started(maximumSilenceNs: 1_000)
        )
        let checkpointObservation = try fixture.sceneObservation(
            sequence: 7,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("new baseline"))]
        )
        let newBaseline = try fixture.checkpoint(
            sequence: 7,
            observations: [checkpointObservation]
        )
        let verifiedAgain = try fixture.observation(
            sequence: 8,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("verified again"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [replacement, newBaseline, verifiedAgain]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("A coverage-stream sequence gap requires a later checkpoint")
    func coverageStreamGapRequiresCheckpoint() async throws {
        let fixture = try Fixture()
        let clock = ManualClock(100)
        let store = SceneMemoryStore(
            sessionID: fixture.session,
            receiverMonotonicNow: { clock.now() }
        )
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let stream = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 1, observations: []),
                try fixture.coverage(
                    sequence: 2,
                    stream: stream,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
                try fixture.observation(
                    sequence: 3,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("covered"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)

        let skippedHeartbeat = try fixture.coverage(
            sequence: 4,
            stream: stream,
            scope: .object(object),
            continuity: 3,
            state: .heartbeat
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [skippedHeartbeat]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let replacement = CoverageStreamID()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 5,
                    stream: replacement,
                    scope: .object(object),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000)
                ),
                try fixture.observation(
                    sequence: 6,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("still provisional"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .provisional)

        let recoveryBaseline = try fixture.sceneObservation(
            sequence: 7,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("recovery baseline"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(sequence: 7, observations: [recoveryBaseline]),
                try fixture.observation(
                    sequence: 8,
                    object: object,
                    claims: [ClaimSpec(fixture.label, .text("verified again"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .verifiedCurrent)
    }

    @Test("Field invalidation is scoped and destructive tombstones remove geometry")
    func fieldInvalidationAndTombstones() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let region = SurfaceRegion(
            coordinateSpace: fixture.space,
            rect: try SceneRect(x: 10, y: 20, width: 100, height: 50)
        )
        let observed = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [
                ClaimSpec(fixture.label, .text("button")),
                ClaimSpec(fixture.bounds, .region(region)),
            ]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [observed]),
            through: registration.handle
        )

        let labelChanged = try fixture.invalidation(
            sequence: 2,
            scope: .object(object),
            fields: [fixture.label],
            reason: .valueChanged
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [labelChanged]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.label) == .stale)
        #expect(await freshness(store, object, fixture.bounds) == .provisional)
        #expect(
            await store.lookup(
                at: try ScenePoint(x: 20, y: 30),
                in: fixture.space
            ).candidates.count == 1
        )

        let destroyed = try fixture.invalidation(
            sequence: 3,
            scope: .object(object),
            fields: [],
            reason: .destroyed
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [destroyed]),
            through: registration.handle
        )
        #expect(await freshness(store, object, fixture.bounds) == .stale)
        #expect(
            await store.lookup(
                at: try ScenePoint(x: 20, y: 30),
                in: fixture.space
            ).candidates.isEmpty
        )

        let attemptedResurrection = try fixture.observation(
            sequence: 4,
            object: object,
            claims: [
                ClaimSpec(fixture.label, .text("resurrected")),
            ]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [attemptedResurrection]),
            through: registration.handle
        )
        let stillRetired = await store.lookup(object: object, fields: [fixture.label])?.fields.first
        #expect(stillRetired?.value == .text("button"))
        #expect(stillRetired?.freshness == .stale)

        let checkpointObservation = try fixture.sceneObservation(
            sequence: 5,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("checkpoint resurrection"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.checkpoint(
                    sequence: 5,
                    observations: [checkpointObservation]
                ),
            ]),
            through: registration.handle
        )
        #expect(await store.lookup(object: object) == nil)

        let secureObject = fixture.object()
        let secure = try fixture.observation(
            sequence: 6,
            object: secureObject,
            claims: [ClaimSpec(fixture.label, nil, sensitivity: .secure)]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [secure]),
            through: registration.handle
        )
        let secured = await store.lookup(
            object: secureObject,
            fields: [fixture.label]
        )?.fields.first
        #expect(secured?.value == nil)
        #expect(secured?.freshness == .unknown)

        let privateObject = fixture.object()
        let formerlyOrdinary = try fixture.observation(
            sequence: 7,
            object: privateObject,
            claims: [ClaimSpec(fixture.label, .text("purge me"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [formerlyOrdinary]),
            through: registration.handle
        )
        let privacyBoundary = try fixture.invalidation(
            sequence: 8,
            scope: .object(privateObject),
            fields: [],
            reason: .privacyBoundary
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [privacyBoundary]),
            through: registration.handle
        )
        let purged = await store.lookup(
            object: privateObject,
            fields: [fixture.label]
        )?.fields.first
        #expect(purged?.value == nil)
        #expect(purged?.freshness == .stale)
        let oldReplay = await store.ingest(
            try SceneEventBatch(events: [formerlyOrdinary]),
            through: registration.handle
        )
        #expect(oldReplay.rejection == .invalidBatch)
    }

    @Test("A field becomes stale when its declared dependency is invalidated")
    func dependencyInvalidation() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let sourceObject = fixture.object()
        let derivedObject = fixture.object()
        let meaning = try SceneFieldKey("content.meaning")
        let dependencyRevision = try SourceRevision(
            sourceEpoch: fixture.epoch,
            sequence: 1
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: sourceObject,
                    claims: [ClaimSpec(fixture.label, .text("source"))]
                ),
                try fixture.observation(
                    sequence: 2,
                    object: derivedObject,
                    claims: [
                        ClaimSpec(
                            meaning,
                            .text("derived"),
                            dependencies: [
                                SceneClaimDependency(
                                    revision: dependencyRevision,
                                    object: sourceObject,
                                    field: fixture.label
                                ),
                            ]
                        ),
                    ]
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, derivedObject, meaning) == .provisional)

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.invalidation(
                    sequence: 3,
                    scope: .object(sourceObject),
                    fields: [fixture.label],
                    reason: .valueChanged
                ),
            ]),
            through: registration.handle
        )
        #expect(await freshness(store, derivedObject, meaning) == .stale)
    }
}

@Suite("Scene memory identity, checkpoints, indexing, and bounds")
struct SceneMemoryProjectionTests {
    @Test("A checkpoint replaces only its source projection")
    func checkpointIsolation() async throws {
        let session = SceneSessionID()
        let first = try Fixture(session: session)
        let second = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let firstRegistration = try await first.register(store: store)
        let secondRegistration = try await second.register(store: store)
        let firstObject = first.object()
        let secondObject = second.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try first.observation(
                    sequence: 1,
                    object: firstObject,
                    claims: [ClaimSpec(first.label, .text("first"))]
                ),
            ]),
            through: firstRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try second.observation(
                    sequence: 1,
                    object: secondObject,
                    claims: [ClaimSpec(second.label, .text("second"))]
                ),
            ]),
            through: secondRegistration.handle
        )

        let checkpoint = try first.checkpoint(sequence: 2, observations: [])
        _ = await store.ingest(
            try SceneEventBatch(events: [checkpoint]),
            through: firstRegistration.handle
        )
        #expect(await store.lookup(object: firstObject) == nil)
        #expect(await store.lookup(object: secondObject)?.fields.first?.value == .text("second"))
    }

    @Test("Canonical identities never merge by geometry or text")
    func conservativeCanonicalIdentity() async throws {
        let session = SceneSessionID()
        let first = try Fixture(session: session)
        let second = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let firstRegistration = try await first.register(store: store)
        let secondRegistration = try await second.register(store: store)
        let firstObject = first.object()
        let secondObject = second.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try first.observation(
                    sequence: 1,
                    object: firstObject,
                    claims: [ClaimSpec(first.label, .text("same"))]
                ),
            ]),
            through: firstRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try second.observation(
                    sequence: 1,
                    object: secondObject,
                    claims: [ClaimSpec(second.label, .text("same"))]
                ),
            ]),
            through: secondRegistration.handle
        )
        let firstID = await store.canonicalIdentity(for: firstObject)
        let secondID = await store.canonicalIdentity(for: secondObject)
        #expect(firstID != nil)
        #expect(firstID != secondID)

        let update = try first.observation(
            sequence: 2,
            object: firstObject,
            claims: [ClaimSpec(first.label, .text("updated"))]
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [update]),
            through: firstRegistration.handle
        )
        #expect(await store.canonicalIdentity(for: firstObject) == firstID)
    }

    @Test("A source restart makes its prior projection historical")
    func sourceRestartCreatesHistoricalBoundary() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let oldObject = fixture.object()
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: oldObject,
                    claims: [ClaimSpec(fixture.label, .text("old"))]
                ),
            ]),
            through: registration.handle
        )

        let restarted = try Fixture(
            session: fixture.session,
            device: fixture.device,
            sourceID: fixture.sourceID
        )
        _ = try await restarted.register(store: store)
        #expect(await freshness(store, oldObject, fixture.label) == .historical)

        let rejected = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 2,
                    object: oldObject,
                    claims: [ClaimSpec(fixture.label, .text("late"))]
                ),
            ]),
            through: registration.handle
        )
        #expect(rejected.rejection == .staleEpoch)
    }

    @Test("Closed fresh epochs do not consume the active registration budget")
    func repeatedRestartsReleaseRegistrationBudget() async throws {
        let fixture = try Fixture()
        let limits = try SceneMemoryLimits(maximumRegisteredSources: 1)
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)

        for _ in 0 ..< 8 {
            let epoch = try Fixture(
                session: fixture.session,
                device: fixture.device,
                sourceID: fixture.sourceID
            )
            let registration = try await epoch.register(store: store)
            #expect(await store.closeSource(registration.handle))
        }

        let finalEpoch = try Fixture(
            session: fixture.session,
            device: fixture.device,
            sourceID: fixture.sourceID
        )
        _ = try await finalEpoch.register(store: store)
        #expect(await store.statistics().registeredSources == 1)
    }

    @Test("Spatial lookup requires an exact coordinate revision")
    func coordinateRevisionIsolation() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let region = SurfaceRegion(
            coordinateSpace: fixture.space,
            rect: try SceneRect(x: 50, y: 50, width: 20, height: 20)
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: object,
                    claims: [ClaimSpec(fixture.bounds, .region(region))]
                ),
            ]),
            through: registration.handle
        )
        let point = try ScenePoint(x: 55, y: 55)
        #expect(await store.lookup(at: point, in: fixture.space).candidates.count == 1)
        let hotSnapshot = await store.spatialSnapshot()
        #expect(hotSnapshot.lookup(at: point, in: fixture.space).candidates.count == 1)

        let revised = try SurfaceCoordinateSpace(
            surface: fixture.space.surface,
            coordinateSpaceID: fixture.space.coordinateSpaceID,
            revision: fixture.space.revision + 1
        )
        #expect(await store.lookup(at: point, in: revised).candidates.isEmpty)
        #expect(hotSnapshot.lookup(at: point, in: revised).candidates.isEmpty)
    }

    @Test("The immutable hot snapshot uses bounded spatial buckets")
    func bucketedHotSnapshot() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        var events: [SceneEventEnvelope] = []
        for index in 0 ..< 64 {
            let region = SurfaceRegion(
                coordinateSpace: fixture.space,
                rect: try SceneRect(
                    x: Double(index * 256),
                    y: 0,
                    width: 10,
                    height: 10
                )
            )
            events.append(
                try fixture.observation(
                    sequence: UInt64(index + 1),
                    object: fixture.object(),
                    claims: [ClaimSpec(fixture.bounds, .region(region))]
                )
            )
        }
        _ = await store.ingest(
            try SceneEventBatch(events: events),
            through: registration.handle
        )

        let snapshot = await store.spatialSnapshot()
        let point = try ScenePoint(x: Double(32 * 256 + 1), y: 1)
        let result = snapshot.lookup(at: point, in: fixture.space)
        #expect(snapshot.indexedObjects == 64)
        #expect(result.candidates.count == 1)
        #expect(result.examinedCandidates <= 2)
        #expect(!result.didDropCandidates)
        #expect(!result.didTruncateCandidates)
        #expect(result.isComplete)
    }

    @Test("Thousands of overlapping large regions keep synchronous lookup bounded")
    func overlappingLargeRegionsStayBounded() async throws {
        let historicalFixture = try Fixture()
        let limits = try SceneMemoryLimits(
            maximumObjects: 3_000,
            maximumFields: 6_000,
            maximumEstimatedBytes: 64 * 1_024 * 1_024,
            maximumReplayEntriesPerSource: 3_000
        )
        let store = SceneMemoryStore(
            sessionID: historicalFixture.session,
            limits: limits
        )
        let historicalRegistration = try await historicalFixture.register(store: store)

        let historicalCount = 2_048
        for batchStart in stride(from: 0, to: historicalCount, by: 256) {
            let batchEnd = min(batchStart + 256, historicalCount)
            var events: [SceneEventEnvelope] = []
            events.reserveCapacity(batchEnd - batchStart)
            for index in batchStart ..< batchEnd {
                let extent = 8_192 + Double(index % 64)
                let region = SurfaceRegion(
                    coordinateSpace: historicalFixture.space,
                    rect: try SceneRect(x: 0, y: 0, width: extent, height: extent)
                )
                events.append(
                    try historicalFixture.observation(
                        sequence: UInt64(index + 1),
                        object: historicalFixture.object(),
                        claims: [ClaimSpec(historicalFixture.bounds, .region(region))]
                    )
                )
            }
            let receipt = await store.ingest(
                try SceneEventBatch(events: events),
                through: historicalRegistration.handle
            )
            #expect(receipt.status == .accepted)
        }

        // A new epoch makes all of the crowded candidates historical. Two active
        // candidates prove both ordering dimensions: active beats historical, then
        // the smaller active region wins within the active tier.
        let activeFixture = try Fixture(
            session: historicalFixture.session,
            device: historicalFixture.device,
            sourceID: historicalFixture.sourceID
        )
        let activeRegistration = try await activeFixture.register(store: store)
        let largerActiveObject = activeFixture.object()
        let smallerActiveObject = activeFixture.object()
        let largerActiveRegion = SurfaceRegion(
            coordinateSpace: historicalFixture.space,
            rect: try SceneRect(x: 0, y: 0, width: 20_000, height: 20_000)
        )
        let smallerActiveRegion = SurfaceRegion(
            coordinateSpace: historicalFixture.space,
            rect: try SceneRect(x: 0, y: 0, width: 10_000, height: 10_000)
        )
        let activeReceipt = await store.ingest(
            try SceneEventBatch(events: [
                try activeFixture.observation(
                    sequence: 1,
                    object: largerActiveObject,
                    claims: [ClaimSpec(activeFixture.bounds, .region(largerActiveRegion))]
                ),
                try activeFixture.observation(
                    sequence: 2,
                    object: smallerActiveObject,
                    claims: [ClaimSpec(activeFixture.bounds, .region(smallerActiveRegion))]
                ),
            ]),
            through: activeRegistration.handle
        )
        #expect(activeReceipt.status == .accepted)

        let snapshot = await store.spatialSnapshot()
        let result = snapshot.lookup(
            at: try ScenePoint(x: 1, y: 1),
            in: historicalFixture.space,
            limit: 8
        )
        #expect(snapshot.indexedObjects == historicalCount + 2)
        #expect(
            result.candidates.prefix(2).map(\.sourceObject) ==
                [smallerActiveObject, largerActiveObject]
        )
        #expect(result.examinedCandidates <= result.examinationLimit)
        #expect(result.examinationLimit == SceneSpatialSnapshot.maximumExaminedCandidates)
        #expect(result.didDropCandidates)
        #expect(result.didTruncateCandidates)
        #expect(!result.isComplete)

        let hydratedResult = await store.lookup(
            at: try ScenePoint(x: 1, y: 1),
            in: historicalFixture.space,
            limit: 8
        )
        #expect(
            hydratedResult.candidates.prefix(2).map(\.sourceObject) ==
                [smallerActiveObject, largerActiveObject]
        )
        #expect(hydratedResult.examinedCandidates <= hydratedResult.examinationLimit)
        #expect(hydratedResult.didDropCandidates)
        #expect(hydratedResult.didTruncateCandidates)
        #expect(!hydratedResult.isComplete)
    }

    @Test("Spatial ranking does not overflow for extreme finite geometry")
    func extremeGeometryRanking() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let largerObject = fixture.object()
        let smallerObject = fixture.object()
        let largerRegion = SurfaceRegion(
            coordinateSpace: fixture.space,
            rect: try SceneRect(x: 0, y: 0, width: 1e308, height: 2)
        )
        let smallerRegion = SurfaceRegion(
            coordinateSpace: fixture.space,
            rect: try SceneRect(x: 0, y: 0, width: 9e307, height: 2)
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: largerObject,
                    claims: [ClaimSpec(fixture.bounds, .region(largerRegion))]
                ),
                try fixture.observation(
                    sequence: 2,
                    object: smallerObject,
                    claims: [ClaimSpec(fixture.bounds, .region(smallerRegion))]
                ),
            ]),
            through: registration.handle
        )

        let result = await store.lookup(
            at: try ScenePoint(x: 1, y: 1),
            in: fixture.space
        )
        #expect(result.candidates.map(\.sourceObject) == [smallerObject, largerObject])
        #expect(result.examinedCandidates == 2)
        #expect(result.isComplete)
    }

    @Test("Stacking metadata outranks area and explicitly invisible geometry is absent")
    func stackingAndVisibilityHints() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let processID = try SceneFieldKey("application.pid")
        let frontToBack = try SceneFieldKey("window.frontToBackIndex")
        let isOnScreen = try SceneFieldKey("window.isOnScreen")
        let alpha = try SceneFieldKey("window.alpha")
        let visibleWindow = fixture.object()
        let inferredAX = fixture.object()
        let directAX = fixture.object()
        let unknownAX = fixture.object()
        let offscreenWindow = fixture.object()
        let transparentWindow = fixture.object()

        func region(_ size: Double) throws -> SurfaceRegion {
            SurfaceRegion(
                coordinateSpace: fixture.space,
                rect: try SceneRect(x: 0, y: 0, width: size, height: size)
            )
        }

        let events = [
            try fixture.observation(
                sequence: 1,
                object: offscreenWindow,
                claims: [
                    ClaimSpec(fixture.bounds, .region(try region(8)), evidence: .windowMetadata),
                    ClaimSpec(processID, .signedInteger(42), evidence: .windowMetadata),
                    ClaimSpec(frontToBack, .unsignedInteger(0), evidence: .windowMetadata),
                    ClaimSpec(isOnScreen, .boolean(false), evidence: .windowMetadata),
                    ClaimSpec(alpha, .number(1), evidence: .windowMetadata),
                ]
            ),
            try fixture.observation(
                sequence: 2,
                object: transparentWindow,
                claims: [
                    ClaimSpec(fixture.bounds, .region(try region(7)), evidence: .windowMetadata),
                    ClaimSpec(processID, .signedInteger(42), evidence: .windowMetadata),
                    ClaimSpec(frontToBack, .unsignedInteger(1), evidence: .windowMetadata),
                    ClaimSpec(isOnScreen, .boolean(true), evidence: .windowMetadata),
                    ClaimSpec(alpha, .number(0), evidence: .windowMetadata),
                ]
            ),
            try fixture.observation(
                sequence: 3,
                object: visibleWindow,
                claims: [
                    ClaimSpec(
                        fixture.bounds,
                        .region(try region(100)),
                        evidence: .windowMetadata
                    ),
                    ClaimSpec(processID, .signedInteger(42), evidence: .windowMetadata),
                    ClaimSpec(frontToBack, .unsignedInteger(2), evidence: .windowMetadata),
                    ClaimSpec(isOnScreen, .boolean(true), evidence: .windowMetadata),
                    ClaimSpec(alpha, .number(1), evidence: .windowMetadata),
                ]
            ),
            try fixture.observation(
                sequence: 4,
                object: inferredAX,
                claims: [
                    ClaimSpec(fixture.bounds, .region(try region(20))),
                    ClaimSpec(processID, .signedInteger(42)),
                ]
            ),
            try fixture.observation(
                sequence: 5,
                object: directAX,
                claims: [
                    ClaimSpec(fixture.bounds, .region(try region(5))),
                    ClaimSpec(processID, .signedInteger(42)),
                    ClaimSpec(frontToBack, .unsignedInteger(7)),
                ]
            ),
            try fixture.observation(
                sequence: 6,
                object: unknownAX,
                claims: [ClaimSpec(fixture.bounds, .region(try region(1)))]
            ),
        ]
        #expect(
            await store.ingest(
                try SceneEventBatch(events: events),
                through: registration.handle
            ).status == .accepted
        )

        let result = await store.spatialSnapshot().lookup(
            at: try ScenePoint(x: 1, y: 1),
            in: fixture.space,
            limit: 8
        )
        #expect(
            result.candidates.map(\.sourceObject) ==
                [inferredAX, visibleWindow, directAX, unknownAX]
        )
        #expect(!result.candidates.map(\.sourceObject).contains(offscreenWindow))
        #expect(!result.candidates.map(\.sourceObject).contains(transparentWindow))

        let byObject = Dictionary(
            uniqueKeysWithValues: result.candidates.map { ($0.sourceObject, $0) }
        )
        #expect(byObject[inferredAX]?.frontToBackIndex == 2)
        #expect(byObject[inferredAX]?.stackingBasis == .inferredApplicationWindow)
        #expect(byObject[visibleWindow]?.frontToBackIndex == 2)
        #expect(byObject[visibleWindow]?.stackingBasis == .directWindow)
        #expect(byObject[visibleWindow]?.isOnScreen == true)
        #expect(byObject[visibleWindow]?.alpha == 1)
        #expect(byObject[directAX]?.frontToBackIndex == 7)
        #expect(byObject[directAX]?.stackingBasis == .directWindow)
        #expect(byObject[unknownAX]?.frontToBackIndex == nil)
    }

    @Test("PID stacking inference never crosses a device boundary")
    func stackingInferenceIsDeviceScoped() async throws {
        let session = SceneSessionID()
        let local = try Fixture(session: session)
        let remote = try Fixture(session: session)
        let store = SceneMemoryStore(sessionID: session)
        let localRegistration = try await local.register(store: store)
        let remoteRegistration = try await remote.register(store: store)
        let processID = try SceneFieldKey("application.pid")
        let frontToBack = try SceneFieldKey("window.frontToBackIndex")
        let isOnScreen = try SceneFieldKey("window.isOnScreen")
        let alpha = try SceneFieldKey("window.alpha")
        let localAXObject = local.object()
        let remoteWindow = remote.object()
        let localRegion = SurfaceRegion(
            coordinateSpace: local.space,
            rect: try SceneRect(x: 0, y: 0, width: 20, height: 20)
        )
        let remoteRegion = SurfaceRegion(
            coordinateSpace: remote.space,
            rect: try SceneRect(x: 0, y: 0, width: 20, height: 20)
        )

        _ = await store.ingest(
            try SceneEventBatch(events: [
                try local.observation(
                    sequence: 1,
                    object: localAXObject,
                    claims: [
                        ClaimSpec(local.bounds, .region(localRegion)),
                        ClaimSpec(processID, .signedInteger(42)),
                    ]
                ),
            ]),
            through: localRegistration.handle
        )
        _ = await store.ingest(
            try SceneEventBatch(events: [
                try remote.observation(
                    sequence: 1,
                    object: remoteWindow,
                    claims: [
                        ClaimSpec(remote.bounds, .region(remoteRegion), evidence: .windowMetadata),
                        ClaimSpec(processID, .signedInteger(42), evidence: .windowMetadata),
                        ClaimSpec(frontToBack, .unsignedInteger(0), evidence: .windowMetadata),
                        ClaimSpec(isOnScreen, .boolean(true), evidence: .windowMetadata),
                        ClaimSpec(alpha, .number(1), evidence: .windowMetadata),
                    ]
                ),
            ]),
            through: remoteRegistration.handle
        )

        let result = await store.spatialSnapshot().lookup(
            at: try ScenePoint(x: 1, y: 1),
            in: local.space,
            limit: 8
        )
        let localCandidate = result.candidates.first {
            $0.sourceObject == localAXObject
        }
        #expect(localCandidate?.frontToBackIndex == nil)
        #expect(localCandidate?.stackingBasis == nil)
    }

    @Test("Multi-object hydration is prefix-bounded and empty fields means zero fields")
    func multiObjectHydrationHardCaps() async throws {
        let fixture = try Fixture()
        let store = SceneMemoryStore(sessionID: fixture.session)
        let registration = try await fixture.register(store: store)
        let objects = (0 ..< 65).map { _ in fixture.object() }
        let events = try objects.enumerated().map { index, object in
            try fixture.observation(
                sequence: UInt64(index + 1),
                object: object,
                claims: [ClaimSpec(fixture.label, .text("object-\(index)"))]
            )
        }
        _ = await store.ingest(
            try SceneEventBatch(events: events),
            through: registration.handle
        )

        let empty = await store.lookup(objects: objects, fields: [])
        #expect(empty.count == 64)
        #expect(empty.map(\.sourceObject) == Array(objects.prefix(64)))
        #expect(empty.allSatisfy { $0.fields.isEmpty })

        let requestedFields = try (0 ..< 65).map {
            try SceneFieldKey("test.hydration.field.\($0)")
        }
        let bounded = await store.lookup(objects: objects, fields: requestedFields)
        #expect(bounded.count == 64)
        #expect(bounded.allSatisfy { $0.fields.count == 64 })
        #expect(
            bounded.first?.fields.map(\.field) ==
                Array(requestedFields.prefix(64)).sorted()
        )
    }

    @Test("Mutation-order eviction and replay windows are deterministic")
    func deterministicBounds() async throws {
        let fixture = try Fixture()
        let limits = try SceneMemoryLimits(
            maximumRegisteredSources: 4,
            maximumObjects: 2,
            maximumFields: 8,
            maximumEstimatedBytes: 1_000_000,
            maximumReplayEntriesPerSource: 2,
            maximumCoverageStreamsPerSource: 4
        )
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)
        let registration = try await fixture.register(store: store)
        let objects = [fixture.object(), fixture.object(), fixture.object()]
        var events: [SceneEventEnvelope] = []
        for (index, object) in objects.enumerated() {
            let event = try fixture.observation(
                sequence: UInt64(index + 1),
                object: object,
                claims: [ClaimSpec(fixture.label, .text("object-\(index)"))]
            )
            events.append(event)
            _ = await store.ingest(
                try SceneEventBatch(events: [event]),
                through: registration.handle
            )
        }
        #expect(await store.lookup(object: objects[0]) == nil)
        #expect(await store.lookup(object: objects[1]) != nil)
        #expect(await store.lookup(object: objects[2]) != nil)
        #expect(await store.statistics().objects == 2)
        #expect(await store.statistics().replayEntries == 2)

        let retainedReplay = await store.ingest(
            try SceneEventBatch(events: [events[1]]),
            through: registration.handle
        )
        #expect(retainedReplay.status == .accepted)
        #expect(retainedReplay.identicalReplays == [events[1].revision])

        let evictedReplay = await store.ingest(
            try SceneEventBatch(events: [events[0]]),
            through: registration.handle
        )
        #expect(evictedReplay.status == .rejected)
        #expect(evictedReplay.rejection == .invalidBatch)
    }

    @Test("The byte budget sheds replay payloads before live objects")
    func byteBudgetPrefersLiveObjects() async throws {
        let fixture = try Fixture()
        let limits = try SceneMemoryLimits(
            maximumRegisteredSources: 2,
            maximumObjects: 2,
            maximumFields: 4,
            maximumEstimatedBytes: 600,
            maximumReplayEntriesPerSource: 4,
            maximumCoverageStreamsPerSource: 2
        )
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let event = try fixture.observation(
            sequence: 1,
            object: object,
            claims: [ClaimSpec(fixture.label, .text("live"))]
        )
        let receipt = await store.ingest(
            try SceneEventBatch(events: [event]),
            through: registration.handle
        )
        #expect(receipt.status == .accepted)
        #expect(await store.lookup(object: object) != nil)
        let statistics = await store.statistics()
        #expect(statistics.replayEntries == 0)
        #expect(statistics.estimatedBytes <= 600)
    }

    @Test("Coverage-only budget eviction rebuilds the spatial snapshot")
    func coverageBudgetEvictionRebuildsSpatialState() async throws {
        let fixture = try Fixture()
        let limits = try SceneMemoryLimits(maximumEstimatedBytes: 800)
        let store = SceneMemoryStore(sessionID: fixture.session, limits: limits)
        let registration = try await fixture.register(store: store)
        let object = fixture.object()
        let region = SurfaceRegion(
            coordinateSpace: fixture.space,
            rect: try SceneRect(x: 0, y: 0, width: 10, height: 10)
        )
        let observed = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.observation(
                    sequence: 1,
                    object: object,
                    claims: [ClaimSpec(fixture.bounds, .region(region))]
                ),
            ]),
            through: registration.handle
        )
        #expect(observed.status == .accepted)
        let priorRevision = await store.spatialSnapshot().revision
        #expect(
            await store.spatialSnapshot().lookup(
                at: try ScenePoint(x: 1, y: 1),
                in: fixture.space
            ).candidates.map(\.sourceObject) == [object]
        )

        let coverage = await store.ingest(
            try SceneEventBatch(events: [
                try fixture.coverage(
                    sequence: 2,
                    stream: CoverageStreamID(),
                    scope: .sourceProjection(fixture.epoch),
                    continuity: 1,
                    state: .started(maximumSilenceNs: 1_000),
                    guarantee: .bestEffort
                ),
            ]),
            through: registration.handle
        )
        #expect(coverage.status == .accepted)
        let after = await store.spatialSnapshot()
        #expect(after.revision > priorRevision)
        #expect(after.indexedObjects == 0)
        #expect(await store.lookup(object: object) == nil)
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private struct ClaimSpec {
    let field: SceneFieldKey
    let value: SceneFieldValue?
    let sensitivity: SceneDataSensitivity
    let evidence: SceneEvidenceKind
    let dependencies: [SceneClaimDependency]

    init(
        _ field: SceneFieldKey,
        _ value: SceneFieldValue?,
        sensitivity: SceneDataSensitivity = .ordinary,
        evidence: SceneEvidenceKind = .accessibility,
        dependencies: [SceneClaimDependency] = []
    ) {
        self.field = field
        self.value = value
        self.sensitivity = sensitivity
        self.evidence = evidence
        self.dependencies = dependencies
    }
}

private struct Fixture {
    let session: SceneSessionID
    let device: DevicePrincipalID
    let sourceID: SceneSourceID
    let epoch: SceneSourceEpoch
    let space: SurfaceCoordinateSpace
    let label: SceneFieldKey
    let bounds: SceneFieldKey

    init(
        session: SceneSessionID = SceneSessionID(),
        device: DevicePrincipalID = DevicePrincipalID(),
        sourceID: SceneSourceID = SceneSourceID()
    ) throws {
        self.session = session
        self.device = device
        self.sourceID = sourceID
        self.epoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: sourceID)
        )
        self.space = try SurfaceCoordinateSpace(
            surface: SceneSurfaceIdentity(device: device, surfaceID: SceneSurfaceID()),
            coordinateSpaceID: CoordinateSpaceID(),
            revision: 1
        )
        self.label = try SceneFieldKey("content.label")
        self.bounds = try SceneFieldKey("geometry.bounds")
    }

    func object(id: SourceObjectID = SourceObjectID()) -> SourceObjectKey {
        SourceObjectKey(sourceEpoch: epoch, objectID: id)
    }

    func register(
        store: SceneMemoryStore,
        expiry: UInt64? = nil,
        permittedDependencySources: Set<SceneSourceIdentity> = []
    ) async throws -> RegisteredSceneSource {
        var capabilities: Set<SceneSourceCapability> = [
            .structuredHierarchy,
            .geometry,
            .text,
            .coverageReporting,
            .completeEventCoverage,
            .checkpoints,
        ]
        if !permittedDependencySources.isEmpty {
            capabilities.insert(.crossSourceDependencies)
        }
        let manifest = try SceneSourceManifest(
            sourceEpoch: epoch,
            sessionID: session,
            displayName: "Memory fixture",
            kind: .syntheticTest,
            capabilities: Array(capabilities)
        )
        return try await store.register(
            manifest: manifest,
            authorization: SceneSourceGrantPolicy(
                capabilities: capabilities,
                eventKinds: Set(SceneEventKind.allCases),
                evidenceKinds: [.accessibility, .windowMetadata],
                fields: .all,
                surfaces: .ownDevice,
                permittedDependencySources: permittedDependencySources,
                expiresAtReceiverMonotonicNs: expiry
            )
        )
    }

    func observation(
        sequence: UInt64,
        object: SourceObjectKey,
        claims specs: [ClaimSpec]
    ) throws -> SceneEventEnvelope {
        let observation = try sceneObservation(
            sequence: sequence,
            object: object,
            claims: specs
        )
        return try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sequence,
            payload: .observation(observation)
        )
    }

    func sceneObservation(
        sequence: UInt64,
        object: SourceObjectKey,
        claims specs: [ClaimSpec]
    ) throws -> SceneObservation {
        let revision = try SourceRevision(sourceEpoch: epoch, sequence: sequence)
        let claims = try specs.map { spec in
            try SceneFieldClaim(
                field: spec.field,
                value: spec.value,
                knowledge: .observed,
                confidence: 1,
                sensitivity: spec.sensitivity,
                evidence: [
                    try SceneEvidence(kind: spec.evidence, sourceRevision: revision),
                ],
                dependencies: spec.dependencies
            )
        }
        return try SceneObservation(
            subject: object,
            observedAtSourceMonotonicNs: sequence,
            claims: claims
        )
    }

    func invalidation(
        sequence: UInt64,
        scope: SceneInvalidationScope,
        fields: [SceneFieldKey],
        reason: SceneInvalidationReason
    ) throws -> SceneEventEnvelope {
        let invalidation = try SceneInvalidation(
            scope: scope,
            fields: fields,
            reason: reason,
            observedAtSourceMonotonicNs: sequence
        )
        return try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sequence,
            payload: .invalidation(invalidation)
        )
    }

    func coverage(
        sequence: UInt64,
        stream: CoverageStreamID,
        scope: SceneCoverageScope,
        continuity: UInt64,
        state: CoverageReportState,
        guarantee: CoverageGuarantee = .completeEvents,
        sourceTime: UInt64? = nil
    ) throws -> SceneEventEnvelope {
        let report = try CoverageReport(
            streamID: stream,
            scope: scope,
            continuitySequence: continuity,
            state: state,
            guarantee: guarantee,
            coveredFields: [label],
            coveredEvidenceKinds: [.accessibility],
            observedAtSourceMonotonicNs: sourceTime ?? sequence
        )
        return try SceneEventEnvelope(
            revision: SourceRevision(sourceEpoch: epoch, sequence: sequence),
            emittedAtSourceMonotonicNs: sourceTime ?? sequence,
            payload: .coverage(report)
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
}

private func freshness(
    _ store: SceneMemoryStore,
    _ object: SourceObjectKey,
    _ field: SceneFieldKey
) async -> SceneFieldFreshness? {
    await store.lookup(object: object, fields: [field])?.fields.first?.freshness
}
