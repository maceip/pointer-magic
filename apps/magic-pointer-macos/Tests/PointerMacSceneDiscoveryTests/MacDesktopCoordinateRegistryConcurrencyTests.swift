import Foundation
@testable import PointerMacSceneDiscovery
import PointerSceneContracts
import Testing

@Suite("coordinate registry publication concurrency", .serialized)
struct MacDesktopCoordinateRegistryConcurrencyTests {
    @Test("display revision history fails closed at its session cap")
    func retainedDisplayIdentitiesAreBoundedWithoutRevisionReuse() throws {
        let registry = MacDesktopCoordinateRegistry(
            device: DevicePrincipalID(),
            candidateConstructionHook: {},
            retainedDisplayIdentityLimit: 2
        )
        let first = display(
            id: 1,
            uuid: "50000000-0000-0000-0000-000000000001"
        )
        let second = display(
            id: 2,
            uuid: "50000000-0000-0000-0000-000000000002"
        )
        let overflow = display(
            id: 3,
            uuid: "50000000-0000-0000-0000-000000000003"
        )

        let firstSnapshot = try registry.update(with: [first])
        registry.invalidateCurrentTopology()
        _ = try registry.update(with: [second])
        registry.invalidateCurrentTopology()

        #expect(throws: MacDesktopCoordinateRegistryError
            .retainedDisplayIdentityLimitExceeded(maximum: 2, actual: 3)) {
            try registry.update(with: [overflow])
        }
        #expect(registry.snapshot() == nil)

        let returned = try registry.update(with: [first])
        let firstSpace = try #require(
            firstSnapshot.displayMappings.first?.descriptor.coordinateSpace
        )
        let returnedSpace = try #require(
            returned.displayMappings.first?.descriptor.coordinateSpace
        )
        #expect(returnedSpace.surface == firstSpace.surface)
        #expect(returnedSpace.revision == firstSpace.revision + 1)
    }

    @Test("cache readers do not wait for topology candidate construction")
    func snapshotDoesNotWaitForWriterConstruction() async throws {
        let gate = CoordinateCandidateConstructionGate()
        let registry = MacDesktopCoordinateRegistry(
            device: DevicePrincipalID(),
            candidateConstructionHook: { gate.pauseIfArmed() }
        )
        let initialDisplay = display(x: 0, width: 1_000)
        let changedDisplay = display(x: -200, width: 1_200)
        let initial = try registry.update(with: [initialDisplay])

        gate.arm()
        let update = CoordinateUpdateCompletion()
        let updateThread = Thread {
            do {
                let snapshot = try registry.update(with: [changedDisplay])
                update.complete(revision: snapshot.topologyRevision)
            } catch {
                update.fail()
            }
        }
        updateThread.name = "MagicPointerTests.CoordinateUpdate"
        updateThread.start()

        for _ in 0 ..< 500 where !gate.isPaused {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard gate.isPaused else {
            gate.release()
            Issue.record("coordinate update never reached candidate construction")
            return
        }

        // This timeout prevents a regression from deadlocking the test. With the
        // former shared lock, snapshot() returns only after this releases the writer.
        let failSafe = Task {
            do {
                try await Task.sleep(for: .milliseconds(750))
                gate.release()
            } catch {
                // The normal fast-reader path cancels this timeout.
            }
        }
        let start = ContinuousClock.now
        let visibleWhileBuilding = registry.snapshot()
        let elapsed = ContinuousClock.now - start
        gate.release()
        failSafe.cancel()
        await failSafe.value

        for _ in 0 ..< 500 where !update.isFinished {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(elapsed < .milliseconds(250))
        #expect(visibleWhileBuilding?.topologyRevision == initial.topologyRevision)
        #expect(!update.failed)
        #expect(update.revision == initial.topologyRevision + 1)
        #expect(registry.snapshot()?.topologyRevision == initial.topologyRevision + 1)
    }

    @Test("invalidation ordered behind an update cannot be overwritten by it")
    func invalidationWinsWhenItArrivesDuringConstruction() async throws {
        let gate = CoordinateCandidateConstructionGate()
        let registry = MacDesktopCoordinateRegistry(
            device: DevicePrincipalID(),
            candidateConstructionHook: { gate.pauseIfArmed() }
        )
        let initial = try registry.update(with: [display(x: 0, width: 1_000)])
        let changedDisplay = display(x: -200, width: 1_200)
        gate.arm()

        let update = CoordinateUpdateCompletion()
        let updateThread = Thread {
            do {
                let snapshot = try registry.update(with: [changedDisplay])
                update.complete(revision: snapshot.topologyRevision)
            } catch {
                update.fail()
            }
        }
        updateThread.start()

        for _ in 0 ..< 500 where !gate.isPaused {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard gate.isPaused else {
            gate.release()
            Issue.record("coordinate update never reached candidate construction")
            return
        }

        let invalidation = CoordinateOperationCompletion()
        let invalidationThread = Thread {
            invalidation.markStarted()
            registry.invalidateCurrentTopology()
            invalidation.complete()
        }
        invalidationThread.start()
        for _ in 0 ..< 500 where !invalidation.hasStarted {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(invalidation.hasStarted)
        gate.release()

        for _ in 0 ..< 500 where !update.isFinished || !invalidation.isFinished {
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(!update.failed)
        #expect(update.revision == initial.topologyRevision + 1)
        #expect(invalidation.isFinished)
        #expect(registry.snapshot() == nil)
    }

    private func display(
        id: UInt32 = 1,
        uuid: String = "50000000-0000-0000-0000-000000000001",
        x: Double = 0,
        width: Double = 1_000
    ) -> MacDisplaySnapshot {
        MacDisplaySnapshot(
            displayID: id,
            displayUUID: UUID(uuidString: uuid),
            globalBounds: MacGlobalRect(x: x, y: 0, width: width, height: 700)!,
            pixelWidth: Int(width * 2),
            pixelHeight: 1_400,
            rotationQuarterTurns: 0,
            scaleFactor: 2,
            isMain: true
        )
    }
}

private final class CoordinateCandidateConstructionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var paused = false
    private var released = false

    var isPaused: Bool {
        condition.lock()
        let result = paused
        condition.unlock()
        return result
    }

    func arm() {
        condition.lock()
        armed = true
        paused = false
        released = false
        condition.unlock()
    }

    func pauseIfArmed() {
        condition.lock()
        guard armed else {
            condition.unlock()
            return
        }
        paused = true
        condition.broadcast()
        while !released { condition.wait() }
        armed = false
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CoordinateUpdateCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var _revision: UInt64?
    private var _failed = false
    private var _isFinished = false

    var revision: UInt64? {
        lock.withLock { _revision }
    }

    var failed: Bool {
        lock.withLock { _failed }
    }

    var isFinished: Bool {
        lock.withLock { _isFinished }
    }

    func complete(revision: UInt64) {
        lock.withLock {
            _revision = revision
            _isFinished = true
        }
    }

    func fail() {
        lock.withLock {
            _failed = true
            _isFinished = true
        }
    }
}

private final class CoordinateOperationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func markStarted() {
        lock.withLock { started = true }
    }

    func complete() {
        lock.withLock { finished = true }
    }
}
