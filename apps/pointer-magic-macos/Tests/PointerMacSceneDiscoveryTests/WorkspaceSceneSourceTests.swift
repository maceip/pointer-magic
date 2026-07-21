import Dispatch
import Foundation
@testable import PointerMacSceneDiscovery
@testable import PointerSceneContracts
import Testing

@Suite("workspace scene source", .serialized)
struct WorkspaceSceneSourceTests {
    @Test("starts with a checkpoint and stop ends independent best-effort coverage")
    func lifecycleOrdering() async throws {
        let device = DevicePrincipalID(rawValue: UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!)
        let session = SceneSessionID(rawValue: UUID(
            uuidString: "10000000-0000-0000-0000-000000000002"
        )!)
        let source = try WorkspaceSceneSource(
            device: device,
            sessionID: session,
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device),
            censusProvider: FixedCensusProvider(census: census()),
            clock: FixedWorkspaceClock(),
            heartbeatInterval: .seconds(3_600),
            periodicCensusCadence: WorkspacePeriodicCensusCadence(
                intervalSeconds: 300
            )
        )
        let handle = makeHandle(manifest: source.manifest)
        let sink = WorkspaceRecordingSink()

        try await source.start(handle: handle, sink: sink)
        await source.stop()
        await source.stop()

        let events = await sink.events()
        #expect(events.first?.revision.sequence == 1)
        if case let .checkpoint(checkpoint)? = events.first?.payload {
            #expect(!checkpoint.observations.isEmpty)
        } else {
            Issue.record("first source event was not the initial checkpoint")
        }

        let coverage = events.compactMap { event -> CoverageReport? in
            if case let .coverage(report) = event.payload { return report }
            return nil
        }
        #expect(coverage.count == 2)
        if case .started = coverage.first?.state {
            // Expected.
        } else {
            Issue.record("coverage did not start after the checkpoint")
        }
        if case .ended(.producerPaused) = coverage.last?.state {
            // Expected.
        } else {
            Issue.record("stop did not end coverage")
        }
        #expect(coverage.allSatisfy { $0.guarantee == .bestEffort })
    }

    @Test("proactive census cadence is bounded independently of heartbeat")
    func periodicCadenceBounds() {
        #expect(WorkspacePeriodicCensusCadence().intervalSeconds == 15)
        #expect(WorkspacePeriodicCensusCadence(intervalSeconds: 0).intervalSeconds == 5)
        #expect(WorkspacePeriodicCensusCadence(intervalSeconds: 30).intervalSeconds == 30)
        #expect(WorkspacePeriodicCensusCadence(intervalSeconds: 10_000).intervalSeconds == 300)
    }

    @Test("periodic census never overlaps even when refreshes arrive during work")
    func censusIsSerialized() async throws {
        let device = DevicePrincipalID()
        let census = census()
        let provider = SlowConcurrentCensusProvider(census: census)
        let source = try WorkspaceSceneSource(
            device: device,
            sessionID: SceneSessionID(),
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device),
            censusProvider: provider,
            heartbeatInterval: .seconds(3_600),
            periodicCensusCadence: WorkspacePeriodicCensusCadence(intervalSeconds: 300)
        )
        let sink = WorkspaceRecordingSink()
        try await source.start(handle: makeHandle(manifest: source.manifest), sink: sink)
        let request = try RefreshRequest(
            sessionID: source.manifest.sessionID,
            scope: .sourceProjection(source.manifest.sourceEpoch),
            priority: .utility,
            deadlineAfterNs: 1_000_000_000,
            reason: .explicitUserRequest
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    _ = await source.refresh(request)
                }
            }
        }

        for _ in 0 ..< 100 where provider.captureCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await source.stop()

        #expect(provider.captureCount >= 2)
        #expect(provider.maximumConcurrentCaptures == 1)
    }

    private func makeHandle(manifest: SceneSourceManifest) -> SceneSourceHandle {
        SceneSourceHandle(
            sourceEpoch: manifest.sourceEpoch,
            sessionID: manifest.sessionID,
            grantID: SceneSourceGrantID()
        )
    }

    private func census() -> MacDesktopCensus {
        let display = MacDisplaySnapshot(
            displayID: 1,
            displayUUID: UUID(uuidString: "10000000-0000-0000-0000-000000000003"),
            globalBounds: MacGlobalRect(x: 0, y: 0, width: 1_000, height: 700)!,
            pixelWidth: 2_000,
            pixelHeight: 1_400,
            rotationQuarterTurns: 0,
            scaleFactor: 2,
            isMain: true
        )
        return MacDesktopCensus(displays: [display], applications: [], windows: [])
    }
}

@Suite("workspace checkpoint lane", .serialized)
struct WorkspaceCheckpointLaneTests {
    @Test("census and checkpoint construction run on the owned utility thread")
    @MainActor
    func checkpointUsesOwnedThread() async throws {
        let device = DevicePrincipalID()
        let provider = ThreadRecordingCensusProvider(census: laneCensus())
        let lane = makeLane(device: device, provider: provider)
        lane.start()

        let checkpoint = try await lane.makeCheckpoint()
        #expect(!checkpoint.observations.isEmpty)
        #expect(provider.captureThreadName == WorkspaceCheckpointLane.threadName)
        #expect(provider.captureQualityOfService == .utility)
        #expect(!provider.captureWasMainThread)

        lane.requestStop()
        await lane.waitUntilStopped()
    }

    @Test("cancellation and shutdown wait asynchronously for in-flight census")
    @MainActor
    func cancellationSafeShutdown() async {
        let device = DevicePrincipalID()
        let provider = GatedWorkspaceCensusProvider(census: laneCensus())
        let lane = makeLane(device: device, provider: provider)
        lane.start()
        let build = Task { try await lane.makeCheckpoint() }
        await provider.waitUntilCaptureStarted()

        build.cancel()
        lane.requestStop()
        provider.releaseCapture()

        do {
            _ = try await build.value
            Issue.record("cancelled checkpoint unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        } catch let error as WorkspaceCheckpointLaneError {
            #expect(error == .stopped)
        } catch {
            Issue.record("unexpected checkpoint error: \(error)")
        }
        await lane.waitUntilStopped()
        #expect(provider.captureThreadName == WorkspaceCheckpointLane.threadName)
    }

    private func makeLane(
        device: DevicePrincipalID,
        provider: any MacDesktopCensusProviding
    ) -> WorkspaceCheckpointLane {
        let epoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: SceneSourceID())
        )
        return WorkspaceCheckpointLane(
            censusProvider: provider,
            coordinateRegistry: MacDesktopCoordinateRegistry(device: device),
            observationBuilder: MacSceneObservationBuilder(
                device: device,
                sourceEpoch: epoch
            ),
            clock: FixedWorkspaceClock()
        )
    }

    private func laneCensus() -> MacDesktopCensus {
        MacDesktopCensus(
            displays: [
                MacDisplaySnapshot(
                    displayID: 77,
                    displayUUID: UUID(
                        uuidString: "77000000-0000-0000-0000-000000000077"
                    ),
                    globalBounds: MacGlobalRect(
                        x: 0,
                        y: 0,
                        width: 800,
                        height: 600
                    )!,
                    pixelWidth: 1_600,
                    pixelHeight: 1_200,
                    rotationQuarterTurns: 0,
                    scaleFactor: 2,
                    isMain: true
                ),
            ],
            applications: [],
            windows: []
        )
    }
}

@Suite("workspace scene worker", .serialized)
struct WorkspaceSceneWorkerTests {
    @Test("worker does not drain a second batch before async acknowledgement")
    func oneAtATimeAcknowledgement() async throws {
        let mailbox = BoundedSceneTokenMailbox<WorkspaceSceneToken>(capacity: 4)
        let worker = WorkspaceSceneWorker(mailbox: mailbox)
        var outputs = worker.outputs.makeAsyncIterator()
        worker.start()

        #expect(mailbox.offer(.applicationLifecycle) == .inserted)
        let firstValue = await outputs.next()
        let first = try #require(firstValue)
        #expect(first.drain.tokens == [.applicationLifecycle])

        #expect(mailbox.offer(.activeApplicationChanged) == .inserted)
        let stillPending = try #require(mailbox.drain())
        #expect(stillPending.tokens == [.activeApplicationChanged])

        worker.acknowledge(first.ordinal)
        worker.requestStop()
        await worker.waitUntilStopped()
    }

    @Test("mailbox overflow survives until the acknowledged next drain")
    func backpressureIsExplicit() async throws {
        let mailbox = BoundedSceneTokenMailbox<WorkspaceSceneToken>(capacity: 1)
        let worker = WorkspaceSceneWorker(mailbox: mailbox)
        var outputs = worker.outputs.makeAsyncIterator()
        worker.start()

        #expect(mailbox.offer(.applicationLifecycle) == .inserted)
        let firstValue = await outputs.next()
        let first = try #require(firstValue)

        #expect(mailbox.offer(.activeApplicationChanged) == .inserted)
        #expect(mailbox.offer(.activeSpaceChanged) == .overflowed)
        worker.acknowledge(first.ordinal)

        let secondValue = await outputs.next()
        let second = try #require(secondValue)
        #expect(second.drain.tokens == [.activeApplicationChanged])
        #expect(second.drain.overflowed)

        worker.acknowledge(second.ordinal)
        worker.requestStop()
        await worker.waitUntilStopped()
    }

    @Test("closing an idle worker wakes and finishes its owned thread")
    @MainActor
    func closeWakesIdleThread() async {
        let mailbox = BoundedSceneTokenMailbox<WorkspaceSceneToken>(capacity: 1)
        let worker = WorkspaceSceneWorker(mailbox: mailbox)
        worker.start()

        worker.requestStop()
        await worker.waitUntilStopped()

        var outputs = worker.outputs.makeAsyncIterator()
        let output = await outputs.next()
        #expect(output == nil)
    }

    @Test("periodic census timer offers a distinct token and stops cleanly")
    func periodicTimerLifecycle() async throws {
        let mailbox = BoundedSceneTokenMailbox<WorkspaceSceneToken>(capacity: 4)
        let registration = WorkspaceLifecycleTimerRegistration.start(
            mailbox: mailbox,
            heartbeatInterval: .seconds(3_600),
            periodicCensusInterval: .milliseconds(10),
            periodicCensusLeeway: .milliseconds(1)
        )

        var received: [WorkspaceSceneToken] = []
        for _ in 0 ..< 50 where received.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            received.append(contentsOf: mailbox.drain()?.tokens ?? [])
        }
        #expect(received.contains(.periodicRescan))
        #expect(!received.contains(.heartbeat))

        registration.stop()
        registration.stop()
    }
}

private struct FixedCensusProvider: MacDesktopCensusProviding {
    let census: MacDesktopCensus
    func capture() throws -> MacDesktopCensus { census }
}

private struct FixedWorkspaceClock: SceneSourceMonotonicClock {
    func nowNanoseconds() -> UInt64 { 100 }
}

private final class ThreadRecordingCensusProvider:
    MacDesktopCensusProviding,
    @unchecked Sendable
{
    private let census: MacDesktopCensus
    private let lock = NSLock()
    private var recordedName: String?
    private var recordedQualityOfService: QualityOfService?
    private var recordedMainThread = false

    init(census: MacDesktopCensus) {
        self.census = census
    }

    var captureThreadName: String? {
        lock.withLock { recordedName }
    }

    var captureQualityOfService: QualityOfService? {
        lock.withLock { recordedQualityOfService }
    }

    var captureWasMainThread: Bool {
        lock.withLock { recordedMainThread }
    }

    func capture() throws -> MacDesktopCensus {
        lock.withLock {
            recordedName = Thread.current.name
            recordedQualityOfService = Thread.current.qualityOfService
            recordedMainThread = Thread.isMainThread
        }
        return census
    }
}

private final class GatedWorkspaceCensusProvider:
    MacDesktopCensusProviding,
    @unchecked Sendable
{
    private let census: MacDesktopCensus
    private let condition = NSCondition()
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedName: String?

    init(census: MacDesktopCensus) {
        self.census = census
    }

    var captureThreadName: String? {
        condition.withLock { recordedName }
    }

    func waitUntilCaptureStarted() async {
        await withCheckedContinuation { waiter in
            condition.lock()
            if started {
                condition.unlock()
                waiter.resume()
            } else {
                startWaiters.append(waiter)
                condition.unlock()
            }
        }
    }

    func releaseCapture() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func capture() throws -> MacDesktopCensus {
        condition.lock()
        recordedName = Thread.current.name
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        for waiter in waiters { waiter.resume() }

        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
        return census
    }
}

private final class SlowConcurrentCensusProvider: MacDesktopCensusProviding, @unchecked Sendable {
    let census: MacDesktopCensus

    private let lock = NSLock()
    private var captures = 0
    private var activeCaptures = 0
    private var maximumActiveCaptures = 0

    init(census: MacDesktopCensus) {
        self.census = census
    }

    var captureCount: Int {
        lock.withLock { captures }
    }

    var maximumConcurrentCaptures: Int {
        lock.withLock { maximumActiveCaptures }
    }

    func capture() throws -> MacDesktopCensus {
        lock.lock()
        captures += 1
        activeCaptures += 1
        maximumActiveCaptures = max(maximumActiveCaptures, activeCaptures)
        lock.unlock()

        Thread.sleep(forTimeInterval: 0.02)

        lock.lock()
        activeCaptures -= 1
        lock.unlock()
        return census
    }
}

private actor WorkspaceRecordingSink: SceneEventSink {
    private var received: [SceneEventEnvelope] = []

    func ingest(
        _ batch: SceneEventBatch,
        through _: SceneSourceHandle
    ) async -> IngestReceipt {
        received.append(contentsOf: batch.events)
        return try! IngestReceipt(
            batchID: batch.batchID,
            status: .accepted,
            acceptedThrough: batch.events.last?.revision
        )
    }

    func events() -> [SceneEventEnvelope] { received }
}
