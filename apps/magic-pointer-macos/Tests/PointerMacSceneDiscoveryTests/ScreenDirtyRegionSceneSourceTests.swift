import Foundation
@testable import PointerMacSceneDiscovery
@testable import PointerSceneContracts
import PointerSceneMemory
import Testing

@Suite("screen dirty-region source", .serialized)
struct ScreenDirtyRegionSceneSourceTests {
    @Test("capture excludes only this process to avoid a Halo feedback loop")
    func excludesCurrentProcess() {
        #expect(ScreenDirtyRegionFilterPolicy.excludes(
            applicationProcessID: 88,
            sourceProcessID: 88
        ))
        #expect(!ScreenDirtyRegionFilterPolicy.excludes(
            applicationProcessID: 89,
            sourceProcessID: 88
        ))
    }

    @Test("display sentinels are addressable but absent from pointer spatial probes")
    func sentinelIsNotSemanticGeometry() async throws {
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let registry = MacDesktopCoordinateRegistry(device: device)
        let snapshot = try registry.update(with: [
            MacDisplaySnapshot(
                displayID: 91,
                displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000091"),
                globalBounds: try #require(MacGlobalRect(
                    x: 0,
                    y: 0,
                    width: 100,
                    height: 100
                )),
                pixelWidth: 200,
                pixelHeight: 200,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            ),
        ])
        let provider = DirtyFakeCaptureProvider(permission: true)
        let source = try ScreenDirtyRegionSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: registry,
            sourceID: SceneSourceID(),
            heartbeatInterval: .seconds(60),
            captureProvider: provider
        )
        let store = SceneMemoryStore(sessionID: session)
        let mirror = SceneMemorySnapshotMirror(store: store)
        let registration = try await store.register(
            manifest: source.manifest,
            authorization: MacSceneDiscoveryController.authorization(
                for: .screenDirtyRegions,
                manifest: source.manifest
            )
        )
        try await source.start(handle: registration.handle, sink: mirror)

        let mapping = try #require(snapshot.displayMappings.first)
        let sentinel = SourceObjectKey(
            sourceEpoch: source.manifest.sourceEpoch,
            objectID: SceneStableIdentifiers.screenDirtySentinel(
                surface: mapping.surface,
                device: device
            )
        )
        #expect(await store.lookup(object: sentinel) != nil)
        let globalPoint = try #require(MacGlobalPoint(x: 50, y: 50))
        let mapped = try #require(snapshot.mapQuartzGlobalPoint(globalPoint))
        #expect(mirror.probe(
            at: mapped.point,
            in: mapped.coordinateSpace
        ).candidates.isEmpty)

        await source.stop()
        #expect(await store.closeSource(registration.handle))
    }

    @Test("missing Screen Recording permission never starts capture and publishes a gap")
    func permissionDeniedIsNonPromptingAndHonest() async throws {
        let fixture = try DirtySourceFixture(permission: false)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)

        #expect(fixture.provider.startCount() == 0)
        let events = await fixture.sink.events()
        #expect(events.contains { event in
            guard case let .coverage(report) = event.payload,
                  case .gap(.permissionLost) = report.state
            else { return false }
            return report.guarantee == .bestEffort &&
                report.coveredFields.isEmpty &&
                report.coveredEvidenceKinds.isEmpty
        })
        #expect(events.contains { event in
            guard case let .invalidation(invalidation) = event.payload else { return false }
            return invalidation.reason == .permissionChanged &&
                invalidation.fields == [MacSceneSourceSchema.screenDirtyRevisionField]
        })
        #expect(events.allSatisfy { event in
            if case .observation = event.payload { return false }
            return true
        })
        #expect(fixture.source.manifest.kind == .screenPixels)
        #expect(Set(fixture.source.manifest.capabilities) == [
            .dirtyRegions,
            .coverageReporting,
            .onDemandRefresh,
            .checkpoints,
        ])

        await fixture.source.stop()
    }

    @Test("permission loss after start breaks coverage without restarting capture")
    func permissionLossAfterStart() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        fixture.provider.setPermission(false)
        fixture.provider.offer(.streamStopped(displayID: fixture.displayID))

        let events = await fixture.sink.waitForEvents { events in
            let hasGap = events.contains { event in
                guard case let .coverage(report) = event.payload,
                      case .gap(.permissionLost) = report.state
                else { return false }
                return true
            }
            let hasInvalidation = events.contains { event in
                guard case let .invalidation(invalidation) = event.payload else {
                    return false
                }
                return invalidation.reason == .permissionChanged
            }
            return hasGap && hasInvalidation
        }
        #expect(events.contains { event in
            guard case let .invalidation(invalidation) = event.payload else { return false }
            return invalidation.reason == .permissionChanged
        })
        #expect(fixture.provider.startCount() == 1)
        #expect(fixture.provider.stopCount() == 1)

        await fixture.source.stop()
    }

    @Test("capture failures retry once per heartbeat without restart thrash")
    func captureFailureIsHeartbeatRateLimited() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        #expect(fixture.provider.startCount() == 1)
        fixture.provider.setFailStarts(true)
        fixture.provider.offer(.streamStopped(displayID: fixture.displayID))

        _ = await fixture.sink.waitForEvents { events in
            events.contains { event in
                guard case let .coverage(report) = event.payload,
                      case .gap(.unknown) = report.state
                else { return false }
                return true
            }
        }
        for _ in 0 ..< 1_000 { await Task.yield() }
        #expect(fixture.provider.startCount() == 1)

        fixture.provider.offer(.heartbeat)
        await fixture.provider.waitForStartCount(2)
        for _ in 0 ..< 1_000 { await Task.yield() }
        #expect(fixture.provider.startCount() == 2)

        fixture.provider.offer(.heartbeat)
        await fixture.provider.waitForStartCount(3)
        #expect(fixture.provider.startCount() == 3)

        await fixture.source.stop()
    }

    @Test("stop during suspended startup leaves no open coverage lease")
    func stopDuringSuspendedStartupClosesLocalCoverage() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        await fixture.sink.suspendNextCheckpoint()

        let startTask = Task {
            do {
                try await fixture.source.start(
                    handle: fixture.handle,
                    sink: fixture.sink
                )
                return false
            } catch let error as ScreenDirtyRegionSceneSourceError {
                return error == .stopped
            } catch {
                return false
            }
        }

        await fixture.sink.waitForSuspendedCheckpoint()
        await fixture.source.stop()
        await fixture.sink.resumeSuspendedCheckpoint()
        #expect(await startTask.value)

        let events = await fixture.sink.events()
        let coverageReports: [CoverageReport] = events.compactMap { event in
            guard case let .coverage(report) = event.payload else { return nil }
            return report
        }
        let started = coverageReports.filter { report in
            if case .started = report.state { return true }
            return false
        }
        let ended = coverageReports.filter { report in
            if case .ended = report.state { return true }
            return false
        }
        #expect(started.count == 1)
        #expect(ended.count == 1)
        #expect(started.first?.streamID == ended.first?.streamID)
        #expect(fixture.provider.startCount() == 0)
        #expect(fixture.provider.activeSessionCount() == 0)
    }

    @Test("rejected resync checkpoint stops its uncommitted capture before retry")
    func rejectedCheckpointCannotLeakCaptureSession() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        fixture.provider.setFailStarts(true)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        #expect(fixture.provider.startCount() == 1)
        #expect(fixture.provider.activeSessionCount() == 0)

        fixture.provider.setFailStarts(false)
        await fixture.sink.rejectNextCheckpoint()
        fixture.provider.offer(.heartbeat)
        await fixture.provider.waitForStartCount(2)
        await fixture.provider.waitForStopCount(1)

        #expect(fixture.provider.stopCount() == 1)
        #expect(fixture.provider.activeSessionCount() == 0)
        #expect(fixture.provider.maximumActiveSessionCount() == 1)

        fixture.provider.offer(.heartbeat)
        await fixture.provider.waitForStartCount(3)
        _ = await fixture.sink.waitForEvents { events in
            events.filter { event in
                guard case let .coverage(report) = event.payload,
                      case .started = report.state
                else { return false }
                return true
            }.count >= 2
        }
        #expect(fixture.provider.stopCount() == 1)
        #expect(fixture.provider.activeSessionCount() == 1)
        #expect(fixture.provider.maximumActiveSessionCount() == 1)

        await fixture.source.stop()
        #expect(fixture.provider.stopCount() == 2)
        #expect(fixture.provider.activeSessionCount() == 0)
    }

    @Test("frame callback before capture return waits for committed snapshot")
    func precommitFrameIsRetainedUntilActivation() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        fixture.provider.offerOnNextSuccessfulStart(.frame(try dirtyFrame(
            displayID: fixture.displayID,
            topologyRevision: fixture.snapshot.topologyRevision
        )))

        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        let events = await fixture.sink.waitForEvent { event in
            guard case let .observation(observation) = event.payload else { return false }
            return observation.claims.contains {
                $0.field == MacSceneSourceSchema.screenDirtyRevisionField &&
                    $0.value == .unsignedInteger(1)
            }
        }
        #expect(events.contains { event in
            guard case let .invalidation(invalidation) = event.payload else { return false }
            return invalidation.reason == .contentDirty
        })
        #expect(fixture.provider.activeSessionCount() == 1)

        await fixture.source.stop()
        #expect(fixture.provider.activeSessionCount() == 0)
    }

    @Test("bounded frame metadata updates a stable display sentinel without pixels")
    func frameUpdatesSentinel() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        #expect(fixture.provider.startCount() == 1)

        fixture.provider.offer(.frame(ScreenDirtyRegionFrame(
            displayID: fixture.displayID,
            topologyRevision: fixture.snapshot.topologyRevision,
            outputWidth: 200,
            outputHeight: 100,
            dirtyRects: [try #require(ScreenDirtyPixelRect(
                x: 10,
                y: 10,
                width: 40,
                height: 20
            ))]
        )))

        let events = await fixture.sink.waitForEvent { event in
            guard case let .observation(observation) = event.payload else { return false }
            return observation.claims.contains { claim in
                claim.field == MacSceneSourceSchema.screenDirtyRevisionField &&
                    claim.value == .unsignedInteger(1)
            }
        }
        let dirtyObservation = try #require(events.last(where: { event in
            guard case let .observation(observation) = event.payload else { return false }
            return observation.claims.contains {
                $0.field == MacSceneSourceSchema.screenDirtyRevisionField &&
                    $0.value == .unsignedInteger(1)
            }
        }))
        guard case let .observation(observation) = dirtyObservation.payload else {
            Issue.record("expected sentinel observation")
            return
        }
        #expect(observation.claims.allSatisfy { $0.sensitivity == .ordinary })
        #expect(observation.claims.allSatisfy { claim in
            claim.evidence.allSatisfy { $0.kind == .screenPixels }
        })
        #expect(Set(observation.claims.map(\.field)) ==
            MacSceneSourceSchema.screenDirtyRegionFields)
        #expect(events.contains { event in
            guard case let .invalidation(invalidation) = event.payload else { return false }
            return invalidation.reason == .contentDirty &&
                invalidation.fields == [MacSceneSourceSchema.screenDirtyRevisionField]
        })

        await fixture.source.stop()
        #expect(fixture.provider.stopCount() == 1)
    }

    @Test("repeated fallback topology replacement retains only current sentinel revisions")
    func topologyReplacementBoundsDirtyRevisions() async throws {
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let stableDisplayID: UInt32 = 81
        let fallbackDisplayID: UInt32 = 82
        let displays = [
            MacDisplaySnapshot(
                displayID: stableDisplayID,
                displayUUID: UUID(
                    uuidString: "81000000-0000-0000-0000-000000000081"
                ),
                globalBounds: try #require(MacGlobalRect(
                    x: 0,
                    y: 0,
                    width: 200,
                    height: 100
                )),
                pixelWidth: 400,
                pixelHeight: 200,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            ),
            MacDisplaySnapshot(
                displayID: fallbackDisplayID,
                displayUUID: nil,
                globalBounds: try #require(MacGlobalRect(
                    x: 200,
                    y: 0,
                    width: 200,
                    height: 100
                )),
                pixelWidth: 400,
                pixelHeight: 200,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: false
            ),
        ]
        let registry = MacDesktopCoordinateRegistry(device: device)
        var snapshot = try registry.update(with: displays)
        let provider = DirtyFakeCaptureProvider(permission: true)
        let sink = DirtyRecordingSink()
        let source = try ScreenDirtyRegionSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: registry,
            sourceID: SceneSourceID(),
            heartbeatInterval: .seconds(60),
            clock: DirtyFixedClock(),
            captureProvider: provider
        )
        let handle = SceneSourceHandle(
            sourceEpoch: source.manifest.sourceEpoch,
            sessionID: session,
            grantID: SceneSourceGrantID()
        )
        try await source.start(handle: handle, sink: sink)

        let stableMapping = try #require(snapshot.displayMappings.first {
            $0.display.displayID == stableDisplayID
        })
        let stableSentinel = SceneStableIdentifiers.screenDirtySentinel(
            surface: stableMapping.surface,
            device: device
        )
        provider.offer(.frame(try dirtyFrame(
            displayID: stableDisplayID,
            topologyRevision: snapshot.topologyRevision
        )))
        _ = await sink.waitForEvent { event in
            guard case let .observation(observation) = event.payload,
                  observation.subject.objectID == stableSentinel
            else { return false }
            return observation.claims.contains {
                $0.field == MacSceneSourceSchema.screenDirtyRevisionField &&
                    $0.value == .unsignedInteger(1)
            }
        }

        var retiredFallbackSentinels = Set<SourceObjectID>()
        for _ in 0 ..< 12 {
            let fallbackMapping = try #require(snapshot.displayMappings.first {
                $0.display.displayID == fallbackDisplayID
            })
            let fallbackSentinel = SceneStableIdentifiers.screenDirtySentinel(
                surface: fallbackMapping.surface,
                device: device
            )
            provider.offer(.frame(try dirtyFrame(
                displayID: fallbackDisplayID,
                topologyRevision: snapshot.topologyRevision
            )))
            _ = await sink.waitForEvent { event in
                guard case let .observation(observation) = event.payload,
                      observation.subject.objectID == fallbackSentinel
                else { return false }
                return observation.claims.contains {
                    $0.field == MacSceneSourceSchema.screenDirtyRevisionField &&
                        $0.value == .unsignedInteger(1)
                }
            }
            retiredFallbackSentinels.insert(fallbackSentinel)

            registry.invalidateCurrentTopology()
            snapshot = try registry.update(with: displays)
            let replacementMapping = try #require(snapshot.displayMappings.first {
                $0.display.displayID == fallbackDisplayID
            })
            let replacementSentinel = SceneStableIdentifiers.screenDirtySentinel(
                surface: replacementMapping.surface,
                device: device
            )
            #expect(replacementSentinel != fallbackSentinel)

            provider.offer(.heartbeat)
            _ = await sink.waitForEvent { event in
                guard case let .checkpoint(checkpoint) = event.payload else {
                    return false
                }
                return Set(checkpoint.observations.map(\.subject.objectID)) == [
                    stableSentinel,
                    replacementSentinel,
                ]
            }

            let revisions = await source.dirtyRevisionStateForDiagnostics()
            #expect(revisions.count == 2)
            #expect(revisions[stableSentinel] == 1)
            #expect(revisions[replacementSentinel] == 0)
            #expect(retiredFallbackSentinels.isDisjoint(with: Set(revisions.keys)))
        }

        await source.stop()
    }

    @Test("truncated metadata waits for heartbeat then checkpoints before resuming")
    func metadataOverflowResynchronizes() async throws {
        let fixture = try DirtySourceFixture(permission: true)
        try await fixture.source.start(handle: fixture.handle, sink: fixture.sink)
        fixture.provider.offer(.frame(ScreenDirtyRegionFrame(
            displayID: fixture.displayID,
            topologyRevision: fixture.snapshot.topologyRevision,
            outputWidth: 200,
            outputHeight: 100,
            dirtyRects: [try #require(ScreenDirtyPixelRect(
                x: 1,
                y: 1,
                width: 2,
                height: 2
            ))],
            didTruncateInput: true
        )))

        _ = await fixture.sink.waitForEvents { events in
            events.contains { event in
                guard case let .coverage(report) = event.payload,
                      case .gap(.sourceBackpressure) = report.state
                else { return false }
                return true
            }
        }
        #expect(fixture.provider.startCount() == 1)
        fixture.provider.offer(.heartbeat)
        let events = await fixture.sink.waitForEvents { events in
            events.filter { event in
                guard case let .coverage(report) = event.payload,
                      case .started = report.state
                else { return false }
                return true
            }.count >= 2
        }
        let gapIndex = try #require(events.firstIndex { event in
            guard case let .coverage(report) = event.payload,
                  case .gap(.sourceBackpressure) = report.state
            else { return false }
            return true
        })
        let laterCheckpoint = events[(gapIndex + 1)...].firstIndex { event in
            if case .checkpoint = event.payload { return true }
            return false
        }
        let laterCoverageStart = events[(gapIndex + 1)...].firstIndex { event in
            guard case let .coverage(report) = event.payload,
                  case .started = report.state
            else { return false }
            return true
        }
        #expect(laterCheckpoint != nil)
        #expect(laterCoverageStart != nil)
        if let laterCheckpoint, let laterCoverageStart {
            #expect(laterCheckpoint < laterCoverageStart)
        }

        await fixture.source.stop()
    }

    private func dirtyFrame(
        displayID: UInt32,
        topologyRevision: UInt64
    ) throws -> ScreenDirtyRegionFrame {
        ScreenDirtyRegionFrame(
            displayID: displayID,
            topologyRevision: topologyRevision,
            outputWidth: 400,
            outputHeight: 200,
            dirtyRects: [try #require(ScreenDirtyPixelRect(
                x: 1,
                y: 1,
                width: 10,
                height: 10
            ))]
        )
    }
}

private struct DirtySourceFixture {
    let displayID: UInt32 = 71
    let snapshot: MacDesktopCoordinateSnapshot
    let source: ScreenDirtyRegionSceneSource
    let provider: DirtyFakeCaptureProvider
    let sink = DirtyRecordingSink()
    let handle: SceneSourceHandle

    init(permission: Bool) throws {
        let device = DevicePrincipalID()
        let session = SceneSessionID()
        let registry = MacDesktopCoordinateRegistry(device: device)
        snapshot = try registry.update(with: [
            MacDisplaySnapshot(
                displayID: displayID,
                displayUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000071"),
                globalBounds: try #require(MacGlobalRect(
                    x: -50,
                    y: 20,
                    width: 200,
                    height: 100
                )),
                pixelWidth: 400,
                pixelHeight: 200,
                rotationQuarterTurns: 0,
                scaleFactor: 2,
                isMain: true
            ),
        ])
        provider = DirtyFakeCaptureProvider(permission: permission)
        source = try ScreenDirtyRegionSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: registry,
            sourceID: SceneSourceID(),
            heartbeatInterval: .seconds(60),
            clock: DirtyFixedClock(),
            captureProvider: provider
        )
        let grantID = SceneSourceGrantID()
        handle = SceneSourceHandle(
            sourceEpoch: source.manifest.sourceEpoch,
            sessionID: session,
            grantID: grantID
        )
    }
}

private struct DirtyFixedClock: SceneSourceMonotonicClock {
    func nowNanoseconds() -> UInt64 { 100 }
}

private enum DirtyFakeCaptureError: Error {
    case configuredFailure
}

private final class DirtyFakeCaptureProvider:
    ScreenDirtyRegionCaptureProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var permission: Bool
    private var mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>?
    private var starts = 0
    private var stops = 0
    private var activeSessions = 0
    private var maximumActiveSessions = 0
    private var failStarts = false
    private var nextSuccessfulStartToken: ScreenDirtyRegionSourceToken?
    private var startWaiters: [DirtyCountWaiter] = []
    private var stopWaiters: [DirtyCountWaiter] = []

    init(permission: Bool) {
        self.permission = permission
    }

    func hasScreenRecordingPermission() -> Bool {
        lock.lock()
        let value = permission
        lock.unlock()
        return value
    }

    func startCapture(
        coordinateSnapshot _: MacDesktopCoordinateSnapshot,
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>,
        maximumRectsPerFrame _: Int
    ) async throws -> any ScreenDirtyRegionCaptureSession {
        if recordStartAndShouldFail(mailbox: mailbox) {
            throw DirtyFakeCaptureError.configuredFailure
        }
        if let token = takeSuccessfulStartToken() {
            _ = mailbox.offer(token)
        }
        return DirtyFakeCaptureSession { [weak self] in self?.recordStop() }
    }

    func offer(_ token: ScreenDirtyRegionSourceToken) {
        lock.lock()
        let mailbox = mailbox
        lock.unlock()
        _ = mailbox?.offer(token)
    }

    func setPermission(_ value: Bool) {
        lock.lock()
        permission = value
        lock.unlock()
    }

    func setFailStarts(_ value: Bool) {
        lock.lock()
        failStarts = value
        lock.unlock()
    }

    func offerOnNextSuccessfulStart(_ token: ScreenDirtyRegionSourceToken) {
        lock.lock()
        nextSuccessfulStartToken = token
        lock.unlock()
    }

    func startCount() -> Int {
        lock.lock()
        let value = starts
        lock.unlock()
        return value
    }

    func stopCount() -> Int {
        lock.lock()
        let value = stops
        lock.unlock()
        return value
    }

    func activeSessionCount() -> Int {
        lock.lock()
        let value = activeSessions
        lock.unlock()
        return value
    }

    func maximumActiveSessionCount() -> Int {
        lock.lock()
        let value = maximumActiveSessions
        lock.unlock()
        return value
    }

    func waitForStartCount(_ expected: Int) async {
        if startCount() >= expected { return }
        await withCheckedContinuation { continuation in
            registerStartWaiter(expected: expected, continuation: continuation)
        }
    }

    func waitForStopCount(_ expected: Int) async {
        if stopCount() >= expected { return }
        await withCheckedContinuation { continuation in
            registerStopWaiter(expected: expected, continuation: continuation)
        }
    }

    private func recordStartAndShouldFail(
        mailbox: BoundedSceneTokenMailbox<ScreenDirtyRegionSourceToken>
    ) -> Bool {
        lock.lock()
        starts += 1
        self.mailbox = mailbox
        let shouldFail = failStarts
        if !shouldFail {
            activeSessions += 1
            maximumActiveSessions = max(maximumActiveSessions, activeSessions)
        }
        let ready = startWaiters.filter { starts >= $0.expected }
        startWaiters.removeAll { starts >= $0.expected }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
        return shouldFail
    }

    private func registerStartWaiter(
        expected: Int,
        continuation: CheckedContinuation<Void, Never>
    ) {
        lock.lock()
        if starts >= expected {
            lock.unlock()
            continuation.resume()
        } else {
            startWaiters.append(DirtyCountWaiter(
                expected: expected,
                continuation: continuation
            ))
            lock.unlock()
        }
    }

    private func takeSuccessfulStartToken() -> ScreenDirtyRegionSourceToken? {
        lock.lock()
        let token = nextSuccessfulStartToken
        nextSuccessfulStartToken = nil
        lock.unlock()
        return token
    }

    private func registerStopWaiter(
        expected: Int,
        continuation: CheckedContinuation<Void, Never>
    ) {
        lock.lock()
        if stops >= expected {
            lock.unlock()
            continuation.resume()
        } else {
            stopWaiters.append(DirtyCountWaiter(
                expected: expected,
                continuation: continuation
            ))
            lock.unlock()
        }
    }

    private func recordStop() {
        lock.lock()
        stops += 1
        activeSessions -= 1
        let ready = stopWaiters.filter { stops >= $0.expected }
        stopWaiters.removeAll { stops >= $0.expected }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }
}

private struct DirtyCountWaiter: @unchecked Sendable {
    let expected: Int
    let continuation: CheckedContinuation<Void, Never>
}

private final class DirtyFakeCaptureSession:
    ScreenDirtyRegionCaptureSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let onStop: @Sendable () -> Void
    private var stopped = false

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func stop() async {
        if markStopped() { onStop() }
    }

    private func markStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        stopped = true
        return true
    }
}

private actor DirtyRecordingSink: SceneEventSink {
    private struct Waiter {
        let predicate: @Sendable ([SceneEventEnvelope]) -> Bool
        let continuation: CheckedContinuation<[SceneEventEnvelope], Never>
    }

    private var received: [SceneEventEnvelope] = []
    private var waiters: [Waiter] = []
    private var checkpointsToReject = 0
    private var shouldSuspendNextCheckpoint = false
    private var suspendedCheckpointRelease: CheckedContinuation<Void, Never>?
    private var suspendedCheckpointWaiters: [CheckedContinuation<Void, Never>] = []

    func ingest(
        _ batch: SceneEventBatch,
        through _: SceneSourceHandle
    ) async -> IngestReceipt {
        if shouldSuspendNextCheckpoint,
           batch.events.contains(where: { event in
               if case .checkpoint = event.payload { return true }
               return false
           })
        {
            shouldSuspendNextCheckpoint = false
            await withCheckedContinuation { continuation in
                suspendedCheckpointRelease = continuation
                let enteredWaiters = suspendedCheckpointWaiters
                suspendedCheckpointWaiters.removeAll()
                for waiter in enteredWaiters { waiter.resume() }
            }
        }
        if checkpointsToReject > 0,
           batch.events.contains(where: { event in
               if case .checkpoint = event.payload { return true }
               return false
           })
        {
            checkpointsToReject -= 1
            return try! IngestReceipt(
                batchID: batch.batchID,
                status: .rejected,
                rejection: .reducerUnavailable
            )
        }
        received.append(contentsOf: batch.events)
        let ready = waiters.filter { $0.predicate(received) }
        waiters.removeAll { $0.predicate(received) }
        for waiter in ready { waiter.continuation.resume(returning: received) }
        return try! IngestReceipt(
            batchID: batch.batchID,
            status: .accepted,
            acceptedThrough: batch.events.last?.revision
        )
    }

    func events() -> [SceneEventEnvelope] { received }

    func rejectNextCheckpoint() {
        checkpointsToReject += 1
    }

    func suspendNextCheckpoint() {
        shouldSuspendNextCheckpoint = true
    }

    func waitForSuspendedCheckpoint() async {
        if suspendedCheckpointRelease != nil { return }
        await withCheckedContinuation { continuation in
            suspendedCheckpointWaiters.append(continuation)
        }
    }

    func resumeSuspendedCheckpoint() {
        suspendedCheckpointRelease?.resume()
        suspendedCheckpointRelease = nil
    }

    func waitForEvent(
        _ predicate: @escaping @Sendable (SceneEventEnvelope) -> Bool
    ) async -> [SceneEventEnvelope] {
        await waitForEvents { events in events.contains(where: predicate) }
    }

    func waitForEvents(
        _ predicate: @escaping @Sendable ([SceneEventEnvelope]) -> Bool
    ) async -> [SceneEventEnvelope] {
        if predicate(received) { return received }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(
                predicate: predicate,
                continuation: continuation
            ))
        }
    }
}
