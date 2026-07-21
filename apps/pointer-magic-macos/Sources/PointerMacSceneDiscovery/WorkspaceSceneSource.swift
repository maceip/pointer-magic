@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Dispatch
import Foundation
import PointerSceneContracts

public enum WorkspaceSceneToken: UInt8, Hashable, Sendable {
    case applicationLifecycle
    case activeApplicationChanged
    case activeSpaceChanged
    case displayConfigurationChanged
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case sessionDidResignActive
    case sessionDidBecomeActive
    case explicitRefresh
    case periodicRescan
    case heartbeat
}

public struct WorkspacePeriodicCensusCadence: Equatable, Sendable {
    public static let minimumIntervalSeconds = 5
    public static let maximumIntervalSeconds = 5 * 60
    public static let defaultIntervalSeconds = 15

    public let intervalSeconds: Int

    public init(intervalSeconds: Int = defaultIntervalSeconds) {
        self.intervalSeconds = min(
            Self.maximumIntervalSeconds,
            max(Self.minimumIntervalSeconds, intervalSeconds)
        )
    }
}

public enum WorkspaceSceneSourceError: Error, Equatable, Sendable {
    case alreadyStarted
    case stopped
    case sourceHandleMismatch
    case coordinateRegistryDeviceMismatch
    case sinkRejected(IngestRejectionCode?)
}

private enum WorkspacePauseReason: Hashable, Sendable {
    case systemSleeping
    case screensSleeping
    case inactiveSession
}

/// Window/display topology is intentionally its own source. Accessibility discovery
/// will have a separate source epoch, coverage stream and failure boundary.
public actor WorkspaceSceneSource: SceneDiscoverySource {
    private enum Lifecycle: Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    public nonisolated let manifest: SceneSourceManifest

    private let coordinateRegistry: MacDesktopCoordinateRegistry
    private let clock: any SceneSourceMonotonicClock
    private let mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>
    private let processingWorker: WorkspaceSceneWorker
    private let checkpointLane: WorkspaceCheckpointLane
    private let heartbeatInterval: DispatchTimeInterval
    private let periodicCensusCadence: WorkspacePeriodicCensusCadence
    private let maximumCoverageSilenceNs: UInt64

    private var lifecycle: Lifecycle = .idle
    private var emitter: SceneSourceEmitter?
    private var registration: WorkspaceCallbackRegistration?
    private var workerConsumer: Task<Void, Never>?
    private var pauseReasons: Set<WorkspacePauseReason> = []

    public init(
        device: DevicePrincipalID,
        sessionID: SceneSessionID,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        sourceID: SceneSourceID = SceneSourceID(
            rawValue: UUID(uuidString: "4D505343-5749-4E44-4F57-4D4554410001")!
        ),
        censusProvider: any MacDesktopCensusProviding = SystemMacDesktopCensusProvider(),
        clock: any SceneSourceMonotonicClock = SystemSceneSourceMonotonicClock(),
        mailboxCapacity: Int = 8,
        heartbeatInterval: DispatchTimeInterval = .seconds(5),
        periodicCensusCadence: WorkspacePeriodicCensusCadence =
            WorkspacePeriodicCensusCadence(),
        maximumCoverageSilenceNs: UInt64 = 15_000_000_000
    ) throws {
        guard coordinateRegistry.device == device else {
            throw WorkspaceSceneSourceError.coordinateRegistryDeviceMismatch
        }
        let sourceEpoch = SceneSourceEpoch(
            source: SceneSourceIdentity(device: device, source: sourceID)
        )
        self.manifest = try SceneSourceManifest(
            sourceEpoch: sourceEpoch,
            sessionID: sessionID,
            displayName: "macOS workspace and window metadata",
            kind: .windowMetadata,
            capabilities: [
                .applicationLifecycle,
                .windowTopology,
                .geometry,
                .coverageReporting,
                .onDemandRefresh,
                .checkpoints,
            ]
        )
        self.coordinateRegistry = coordinateRegistry
        self.clock = clock
        let mailbox = BoundedSceneTokenMailbox<WorkspaceSceneToken>(
            capacity: mailboxCapacity
        )
        self.mailbox = mailbox
        self.processingWorker = WorkspaceSceneWorker(mailbox: mailbox)
        self.checkpointLane = WorkspaceCheckpointLane(
            censusProvider: censusProvider,
            coordinateRegistry: coordinateRegistry,
            observationBuilder: MacSceneObservationBuilder(
                device: device,
                sourceEpoch: sourceEpoch
            ),
            clock: clock
        )
        self.heartbeatInterval = heartbeatInterval
        self.periodicCensusCadence = periodicCensusCadence
        self.maximumCoverageSilenceNs = maximumCoverageSilenceNs
    }

    public func start(
        handle: SceneSourceHandle,
        sink: any SceneEventSink
    ) async throws {
        switch lifecycle {
        case .idle:
            break
        case .starting, .running, .stopping:
            throw WorkspaceSceneSourceError.alreadyStarted
        case .stopped:
            throw WorkspaceSceneSourceError.stopped
        }
        guard handle.sourceEpoch == manifest.sourceEpoch,
              handle.sessionID == manifest.sessionID
        else {
            throw WorkspaceSceneSourceError.sourceHandleMismatch
        }

        let emitter = try SceneSourceEmitter(
            sourceEpoch: manifest.sourceEpoch,
            handle: handle,
            sink: sink,
            clock: clock
        )
        self.emitter = emitter

        do {
            checkpointLane.start()
            // Register first. Notifications arriving during the initial census are
            // retained in the mailbox and reconciled by the worker immediately after it starts.
            registration = WorkspaceCallbackRegistration.start(
                mailbox: mailbox,
                heartbeatInterval: heartbeatInterval,
                periodicCensusCadence: periodicCensusCadence
            )
            lifecycle = .starting

            try ensureAccepted(try await emitCheckpoint())
            guard case .starting = lifecycle else {
                throw WorkspaceSceneSourceError.stopped
            }
            try ensureAccepted(await emitter.beginBestEffortCoverage(
                scope: .sourceProjection(manifest.sourceEpoch),
                maximumSilenceNs: maximumCoverageSilenceNs
            ))
            guard case .starting = lifecycle else {
                throw WorkspaceSceneSourceError.stopped
            }
            lifecycle = .running

            let processingWorker = self.processingWorker
            workerConsumer = Task { [weak self, processingWorker] in
                for await output in processingWorker.outputs {
                    if !Task.isCancelled {
                        await self?.process(output.drain)
                    }
                    processingWorker.acknowledge(output.ordinal)
                    if Task.isCancelled { return }
                }
            }
            processingWorker.start()
        } catch {
            registration?.stop()
            registration = nil
            processingWorker.requestStop()
            workerConsumer?.cancel()
            checkpointLane.requestStop()
            if let workerConsumer { await workerConsumer.value }
            self.workerConsumer = nil
            await processingWorker.waitUntilStopped()
            await checkpointLane.waitUntilStopped()
            if await emitter.hasOpenCoverageStream() {
                _ = try? await emitter.endCoverage(.producerPaused)
            }
            self.emitter = nil
            lifecycle = .stopped
            throw error
        }
    }

    public func refresh(_ request: RefreshRequest) async -> RefreshDisposition {
        guard lifecycle == .running,
              request.sessionID == manifest.sessionID
        else {
            return .rejected
        }
        switch request.scope {
        case let .sourceProjection(source) where source != manifest.sourceEpoch:
            return .unsupported
        case let .object(object) where object.sourceEpoch != manifest.sourceEpoch:
            return .unsupported
        case let .surface(surface) where surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        case let .region(region)
            where region.coordinateSpace.surface.device != manifest.sourceEpoch.source.device:
            return .unsupported
        default:
            break
        }
        _ = mailbox.offer(.explicitRefresh)
        return .accepted
    }

    public func stop() async {
        switch lifecycle {
        case .starting, .running:
            break
        case .idle, .stopping, .stopped:
            return
        }
        lifecycle = .stopping

        registration?.stop()
        registration = nil
        processingWorker.requestStop()
        workerConsumer?.cancel()
        checkpointLane.requestStop()
        if let workerConsumer { await workerConsumer.value }
        self.workerConsumer = nil
        await processingWorker.waitUntilStopped()
        await checkpointLane.waitUntilStopped()

        if let emitter, await emitter.hasOpenCoverageStream() {
            _ = try? await emitter.endCoverage(.producerPaused)
        }
        emitter = nil
        pauseReasons.removeAll()
        lifecycle = .stopped
    }

    private func process(_ drain: SceneTokenMailboxDrain<WorkspaceSceneToken>) async {
        guard lifecycle == .running, let emitter else { return }

        let coverageIsCurrent = await emitter.hasActiveCoverage()
        var needsResynchronization = drain.overflowed || !coverageIsCurrent
        var invalidationReasons: [SceneInvalidationReason] = []
        var periodicRescanRequested = false
        var heartbeatRequested = false

        if drain.overflowed {
            await breakCoverageIfCurrent(.sourceBackpressure, emitter: emitter)
        }

        for token in drain.tokens {
            switch token {
            case .systemWillSleep:
                pauseReasons.insert(.systemSleeping)
                coordinateRegistry.invalidateCurrentTopology()
                await breakCoverageIfCurrent(.deviceSleeping, emitter: emitter)
            case .screensDidSleep:
                pauseReasons.insert(.screensSleeping)
                coordinateRegistry.invalidateCurrentTopology()
                await breakCoverageIfCurrent(.deviceSleeping, emitter: emitter)
            case .sessionDidResignActive:
                pauseReasons.insert(.inactiveSession)
                await breakCoverageIfCurrent(.screenLocked, emitter: emitter)
            case .systemDidWake:
                pauseReasons.remove(.systemSleeping)
                needsResynchronization = true
            case .screensDidWake:
                pauseReasons.remove(.screensSleeping)
                needsResynchronization = true
            case .sessionDidBecomeActive:
                pauseReasons.remove(.inactiveSession)
                needsResynchronization = true
            case .applicationLifecycle:
                invalidationReasons.append(.sceneTransition)
            case .activeApplicationChanged:
                invalidationReasons.append(.occlusionChanged)
            case .activeSpaceChanged:
                invalidationReasons.append(.sceneTransition)
            case .displayConfigurationChanged:
                coordinateRegistry.invalidateCurrentTopology()
                invalidationReasons.append(.geometryChanged)
            case .explicitRefresh:
                invalidationReasons.append(.unknown)
            case .periodicRescan:
                periodicRescanRequested = true
            case .heartbeat:
                heartbeatRequested = true
            }
        }

        guard pauseReasons.isEmpty else { return }

        do {
            if needsResynchronization {
                // Explicitly close the broken stream before replacing the projection and
                // opening a new independent best-effort stream.
                if await emitter.hasOpenCoverageStream() {
                    _ = try await emitter.endCoverage(.producerPaused)
                }
                guard canContinueProcessing else { return }
                try ensureAccepted(try await emitCheckpoint())
                guard canContinueProcessing else { return }
                try ensureAccepted(await emitter.beginBestEffortCoverage(
                    scope: .sourceProjection(manifest.sourceEpoch),
                    maximumSilenceNs: maximumCoverageSilenceNs
                ))
            } else if !invalidationReasons.isEmpty {
                let observedAt = clock.nowNanoseconds()
                let payloads = try uniqueReasons(invalidationReasons).map { reason in
                    SceneEventPayload.invalidation(try SceneInvalidation(
                        scope: .sourceProjection(manifest.sourceEpoch),
                        fields: Array(MacSceneSourceSchema.workspaceFields),
                        reason: reason,
                        observedAtSourceMonotonicNs: observedAt
                    ))
                }
                try ensureAccepted(try await emitter.emit(payloads))
                guard canContinueProcessing else { return }
                try ensureAccepted(try await emitCheckpoint())
            } else if periodicRescanRequested {
                // Best-effort periodic reconciliation replaces the projection but
                // does not imply complete event coverage or restart its lease.
                try ensureAccepted(try await emitCheckpoint())
            }

            if heartbeatRequested, canContinueProcessing,
               await emitter.hasActiveCoverage()
            {
                try ensureAccepted(await emitter.heartbeatCoverage())
            }
        } catch {
            // A producer-side failure means silence can no longer support freshness.
            if canContinueProcessing {
                await breakCoverageIfCurrent(.unknown, emitter: emitter)
            }
        }
    }

    private func emitCheckpoint() async throws -> IngestReceipt {
        guard let emitter else { throw WorkspaceSceneSourceError.stopped }
        let checkpoint = try await checkpointLane.makeCheckpoint()
        return try await emitter.emit(.checkpoint(checkpoint))
    }

    private func breakCoverageIfCurrent(
        _ reason: CoverageGapReason,
        emitter: SceneSourceEmitter
    ) async {
        if await emitter.hasActiveCoverage() {
            _ = try? await emitter.gapCoverage(reason)
        }
    }

    private func ensureAccepted(_ receipt: IngestReceipt) throws {
        guard receipt.status != .rejected else {
            throw WorkspaceSceneSourceError.sinkRejected(receipt.rejection)
        }
    }

    private func uniqueReasons(
        _ reasons: [SceneInvalidationReason]
    ) -> [SceneInvalidationReason] {
        var seen = Set<SceneInvalidationReason>()
        return reasons.filter { seen.insert($0).inserted }
    }

    private var canContinueProcessing: Bool {
        guard !Task.isCancelled else { return false }
        if case .running = lifecycle { return true }
        return false
    }
}

enum WorkspaceCheckpointLaneError: Error, Equatable, Sendable {
    case notStarted
    case stopped
    case busy
}

/// Owns all synchronous workspace census, coordinate reconciliation, and checkpoint
/// construction. One bounded pending request may wait behind the active request; all
/// work runs serially on this utility Thread and never occupies a Swift cooperative
/// executor. Cancellation cannot interrupt an OS census, but it retracts pending work
/// and suppresses delivery from an in-flight request. Shutdown is awaited asynchronously.
final class WorkspaceCheckpointLane: @unchecked Sendable {
    static let threadName = "PointerMagic.WorkspaceCheckpoint"

    private struct Request: @unchecked Sendable {
        let id: UUID
        let continuation: CheckedContinuation<SceneCheckpoint, any Error>
    }

    private let censusProvider: any MacDesktopCensusProviding
    private let coordinateRegistry: MacDesktopCoordinateRegistry
    private let observationBuilder: MacSceneObservationBuilder
    private let clock: any SceneSourceMonotonicClock
    private let condition = NSCondition()

    private var thread: Thread?
    private var started = false
    private var stopping = false
    private var finished = false
    private var pending: [Request] = []
    private var runningRequestID: UUID?
    private var knownRequestIDs: Set<UUID> = []
    private var canceledRequestIDs: Set<UUID> = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        censusProvider: any MacDesktopCensusProviding,
        coordinateRegistry: MacDesktopCoordinateRegistry,
        observationBuilder: MacSceneObservationBuilder,
        clock: any SceneSourceMonotonicClock
    ) {
        self.censusProvider = censusProvider
        self.coordinateRegistry = coordinateRegistry
        self.observationBuilder = observationBuilder
        self.clock = clock
    }

    func start() {
        condition.lock()
        guard !started, !stopping, !finished else {
            condition.unlock()
            return
        }
        started = true
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = Self.threadName
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        condition.unlock()
    }

    func makeCheckpoint() async throws -> SceneCheckpoint {
        let requestID = UUID()
        track(requestID)
        defer { forget(requestID) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                submit(Request(id: requestID, continuation: continuation))
            }
        } onCancel: {
            cancel(requestID)
        }
    }

    func requestStop() {
        condition.lock()
        guard !stopping, !finished else {
            condition.unlock()
            return
        }
        stopping = true
        let waiting = pending
        pending.removeAll(keepingCapacity: false)
        for request in waiting { knownRequestIDs.remove(request.id) }
        let finishWithoutThread = thread == nil
        condition.broadcast()
        condition.unlock()

        for request in waiting {
            request.continuation.resume(throwing: WorkspaceCheckpointLaneError.stopped)
        }
        if finishWithoutThread { finish() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { waiter in
            condition.lock()
            if finished {
                condition.unlock()
                waiter.resume()
            } else {
                stopWaiters.append(waiter)
                condition.unlock()
            }
        }
    }

    private func submit(_ request: Request) {
        let error: (any Error)?
        condition.lock()
        if canceledRequestIDs.remove(request.id) != nil {
            error = CancellationError()
        } else if stopping || finished {
            error = WorkspaceCheckpointLaneError.stopped
        } else if !started {
            error = WorkspaceCheckpointLaneError.notStarted
        } else if pending.count >= 1 {
            error = WorkspaceCheckpointLaneError.busy
        } else {
            pending.append(request)
            condition.signal()
            error = nil
        }
        condition.unlock()
        if let error { request.continuation.resume(throwing: error) }
    }

    private func cancel(_ requestID: UUID) {
        var waiting: Request?
        condition.lock()
        if let index = pending.firstIndex(where: { $0.id == requestID }) {
            waiting = pending.remove(at: index)
            knownRequestIDs.remove(requestID)
        } else if runningRequestID == requestID {
            canceledRequestIDs.insert(requestID)
        } else if knownRequestIDs.contains(requestID) {
            // Cancellation can race the continuation body's synchronous submission.
            canceledRequestIDs.insert(requestID)
        }
        condition.unlock()
        waiting?.continuation.resume(throwing: CancellationError())
    }

    private func threadMain() {
        while true {
            condition.lock()
            while pending.isEmpty, !stopping {
                condition.wait()
            }
            guard !stopping, !pending.isEmpty else {
                condition.unlock()
                break
            }
            let request = pending.removeFirst()
            runningRequestID = request.id
            condition.unlock()

            let result: Result<SceneCheckpoint, any Error>
            do {
                let census = try censusProvider.capture()
                let coordinateSnapshot = try coordinateRegistry.update(
                    with: census.displays
                )
                let checkpoint = try observationBuilder.makeCheckpoint(
                    from: census,
                    coordinateSnapshot: coordinateSnapshot,
                    observedAtSourceMonotonicNs: clock.nowNanoseconds()
                )
                result = .success(checkpoint)
            } catch {
                result = .failure(error)
            }

            condition.lock()
            let wasCanceled = canceledRequestIDs.remove(request.id) != nil
            let shouldStop = stopping
            runningRequestID = nil
            knownRequestIDs.remove(request.id)
            condition.broadcast()
            condition.unlock()

            if wasCanceled {
                request.continuation.resume(throwing: CancellationError())
            } else if shouldStop {
                request.continuation.resume(
                    throwing: WorkspaceCheckpointLaneError.stopped
                )
            } else {
                request.continuation.resume(with: result)
            }
        }
        finish()
    }

    private func finish() {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        thread = nil
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        knownRequestIDs.removeAll(keepingCapacity: false)
        canceledRequestIDs.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()

        for waiter in waiters { waiter.resume() }
    }

    private func track(_ requestID: UUID) {
        condition.lock()
        knownRequestIDs.insert(requestID)
        condition.unlock()
    }

    private func forget(_ requestID: UUID) {
        condition.lock()
        knownRequestIDs.remove(requestID)
        canceledRequestIDs.remove(requestID)
        condition.unlock()
    }
}

/// Owns the only blocking workspace-mailbox wait on a dedicated utility thread.
/// The thread emits at most one drain and then waits for async actor processing
/// to acknowledge it, so a slow sink cannot create an unbounded task or result
/// queue. Shutdown closes the mailbox and awaits thread completion without
/// blocking the caller's executor.
final class WorkspaceSceneWorker: @unchecked Sendable {
    struct Output: Sendable {
        let ordinal: UInt64
        let drain: SceneTokenMailboxDrain<WorkspaceSceneToken>
    }

    let outputs: AsyncStream<Output>

    private let mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>
    private let continuation: AsyncStream<Output>.Continuation
    private let condition = NSCondition()
    private var thread: Thread?
    private var nextOrdinal: UInt64 = 0
    private var acknowledgedOrdinal: UInt64 = 0
    private var stopping = false
    private var finished = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>) {
        self.mailbox = mailbox
        let pair = AsyncStream<Output>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        self.outputs = pair.stream
        self.continuation = pair.continuation
    }

    func start() {
        condition.lock()
        guard thread == nil, !stopping, !finished else {
            condition.unlock()
            return
        }
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "PointerMagic.WorkspaceDiscovery"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
        condition.unlock()
    }

    func acknowledge(_ ordinal: UInt64) {
        condition.lock()
        acknowledgedOrdinal = max(acknowledgedOrdinal, ordinal)
        condition.broadcast()
        condition.unlock()
    }

    func requestStop() {
        condition.lock()
        guard !stopping else {
            condition.unlock()
            return
        }
        stopping = true
        let finishWithoutThread = thread == nil
        condition.broadcast()
        condition.unlock()

        mailbox.close()
        if finishWithoutThread { finish() }
    }

    func waitUntilStopped() async {
        await withCheckedContinuation { waiter in
            condition.lock()
            if finished {
                condition.unlock()
                waiter.resume()
            } else {
                stopWaiters.append(waiter)
                condition.unlock()
            }
        }
    }

    private func threadMain() {
        while true {
            condition.lock()
            let shouldStop = stopping
            condition.unlock()
            if shouldStop { break }

            let drain: SceneTokenMailboxDrain<WorkspaceSceneToken>
            switch mailbox.waitAndDrain() {
            case .closed:
                finish()
                return
            case let .drained(value):
                drain = value
            }

            condition.lock()
            guard !stopping else {
                condition.unlock()
                break
            }
            nextOrdinal = nextOrdinal == UInt64.max ? 1 : nextOrdinal + 1
            let ordinal = nextOrdinal
            condition.unlock()

            guard case .enqueued = continuation.yield(Output(
                ordinal: ordinal,
                drain: drain
            )) else {
                break
            }

            condition.lock()
            while acknowledgedOrdinal < ordinal, !stopping {
                condition.wait()
            }
            condition.unlock()
        }
        finish()
    }

    private func finish() {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        thread = nil
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()

        continuation.finish()
        for waiter in waiters { waiter.resume() }
    }
}

/// Owns all public OS callback registrations. Every callback body has exactly one job:
/// offer a value token to the bounded mailbox.
private final class WorkspaceCallbackRegistration: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let observers: [NSObjectProtocol]
    private let displayBridge: DisplayReconfigurationBridge
    private let displayContext: UnsafeMutableRawPointer
    private let timers: WorkspaceLifecycleTimerRegistration
    private let stopLock = NSLock()
    private var stopped = false

    static func start(
        mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicCensusCadence: WorkspacePeriodicCensusCadence
    ) -> WorkspaceCallbackRegistration {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, WorkspaceSceneToken)] = [
            (NSWorkspace.didLaunchApplicationNotification, .applicationLifecycle),
            (NSWorkspace.didTerminateApplicationNotification, .applicationLifecycle),
            (NSWorkspace.didHideApplicationNotification, .applicationLifecycle),
            (NSWorkspace.didUnhideApplicationNotification, .applicationLifecycle),
            (NSWorkspace.didActivateApplicationNotification, .activeApplicationChanged),
            (NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        let observers = names.map { name, token in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                mailbox.offer(token)
            }
        }

        let bridge = DisplayReconfigurationBridge(mailbox: mailbox)
        let context = Unmanaged.passUnretained(bridge).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, context)

        let timers = WorkspaceLifecycleTimerRegistration.start(
            mailbox: mailbox,
            heartbeatInterval: heartbeatInterval,
            periodicCensusCadence: periodicCensusCadence
        )

        return WorkspaceCallbackRegistration(
            notificationCenter: center,
            observers: observers,
            displayBridge: bridge,
            displayContext: context,
            timers: timers
        )
    }

    private init(
        notificationCenter: NotificationCenter,
        observers: [NSObjectProtocol],
        displayBridge: DisplayReconfigurationBridge,
        displayContext: UnsafeMutableRawPointer,
        timers: WorkspaceLifecycleTimerRegistration
    ) {
        self.notificationCenter = notificationCenter
        self.observers = observers
        self.displayBridge = displayBridge
        self.displayContext = displayContext
        self.timers = timers
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()

        timers.stop()
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, displayContext)
        _ = displayBridge // Retain through callback removal.
    }
}

/// Independent heartbeat and proactive-census timers. Both callbacks only offer
/// fixed coalescing tokens; the owned workspace worker performs every census and
/// serializes it behind async acknowledgement.
final class WorkspaceLifecycleTimerRegistration: @unchecked Sendable {
    private let heartbeatTimer: DispatchSourceTimer
    private let periodicCensusTimer: DispatchSourceTimer
    private let stopLock = NSLock()
    private var stopped = false

    static func start(
        mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicCensusCadence: WorkspacePeriodicCensusCadence
    ) -> WorkspaceLifecycleTimerRegistration {
        let interval = DispatchTimeInterval.seconds(periodicCensusCadence.intervalSeconds)
        let leeway = DispatchTimeInterval.seconds(
            min(5, max(1, periodicCensusCadence.intervalSeconds / 10))
        )
        return start(
            mailbox: mailbox,
            heartbeatInterval: heartbeatInterval,
            periodicCensusInterval: interval,
            periodicCensusLeeway: leeway
        )
    }

    static func start(
        mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>,
        heartbeatInterval: DispatchTimeInterval,
        periodicCensusInterval: DispatchTimeInterval,
        periodicCensusLeeway: DispatchTimeInterval
    ) -> WorkspaceLifecycleTimerRegistration {
        let heartbeatTimer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(
                label: "pointer-magic.scene-discovery.heartbeat",
                qos: .utility
            )
        )
        heartbeatTimer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval
        )
        heartbeatTimer.setEventHandler { mailbox.offer(.heartbeat) }
        heartbeatTimer.resume()

        let periodicCensusTimer = DispatchSource.makeTimerSource(
            flags: [],
            queue: DispatchQueue(
                label: "pointer-magic.scene-discovery.periodic-census",
                qos: .utility
            )
        )
        periodicCensusTimer.schedule(
            deadline: .now() + periodicCensusInterval,
            repeating: periodicCensusInterval,
            leeway: periodicCensusLeeway
        )
        periodicCensusTimer.setEventHandler { mailbox.offer(.periodicRescan) }
        periodicCensusTimer.resume()

        return WorkspaceLifecycleTimerRegistration(
            heartbeatTimer: heartbeatTimer,
            periodicCensusTimer: periodicCensusTimer
        )
    }

    private init(
        heartbeatTimer: DispatchSourceTimer,
        periodicCensusTimer: DispatchSourceTimer
    ) {
        self.heartbeatTimer = heartbeatTimer
        self.periodicCensusTimer = periodicCensusTimer
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()

        heartbeatTimer.setEventHandler {}
        heartbeatTimer.cancel()
        periodicCensusTimer.setEventHandler {}
        periodicCensusTimer.cancel()
    }
}

private final class DisplayReconfigurationBridge: @unchecked Sendable {
    let mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>

    init(mailbox: BoundedSceneTokenMailbox<WorkspaceSceneToken>) {
        self.mailbox = mailbox
    }
}

private func displayReconfigurationCallback(
    _: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    // The begin callback describes an in-flight topology. Wait for a completed
    // reconfiguration callback before scheduling a census.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let bridge = Unmanaged<DisplayReconfigurationBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.mailbox.offer(.displayConfigurationChanged)
}
