@preconcurrency import AppKit
import Foundation
import PointerCore
import PointerMacEvents
import PointerMacOverlay
import PointerMacSemantics
import PointerTransport

@MainActor
public protocol PointerBedrockInterface: AnyObject {
    func start() async -> StartReport
    func stop() async
    func frames() -> AsyncStream<PointerFrame>
    func discreteEvents() -> AsyncStream<PointerDiscreteEvent>
    func observeOrderedInput(
        _ handler: @escaping (PointerInputEvent) -> Void
    ) -> PointerInputObservation
    func removeInputObservation(_ observation: PointerInputObservation)
    func semanticUpdates() -> AsyncStream<SemanticSnapshot>
    func currentFrame() -> PointerFrame?
    func resolve(_ request: SemanticRequest) async -> SemanticSnapshot
    func perform(_ request: SemanticActionRequest) async -> SemanticActionResult
    func present(_ scene: OverlayScene) throws
    func clearOverlay(expectedGeneration: UInt64?)
    func permissionStatus() -> PermissionReport
    func requestPermission(_ permission: PointerPermission) -> PermissionState
    func health() -> HealthSnapshot
}

public struct PointerInputObservation: Codable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// The native pointer foundation exposed to higher feature layers.
///
/// Public values are immutable, Codable, Sendable and schema-versioned. Raw `CGEvent`,
/// `AXUIElement`, `NSWindow`, and third-party package types never cross this boundary.
@MainActor
public final class PointerBedrock: PointerBedrockInterface {
    private enum Lifecycle {
        case stopped
        case starting
        case running
        case stopping
    }

    private struct InputObserverSlot {
        var id: UUID
        var handler: ((PointerInputEvent) -> Void)?
    }

    public let configuration: PointerConfiguration

    private let mailbox: MotionMailbox
    private let discreteRing: DiscreteRing
    private let eventMetrics: EventMetrics
    private let pointerTap: PassivePointerTap
    private let semanticResolver: AXSemanticResolver
    private let overlay: HaloOverlayController

    private let frameHub = BroadcastHub<PointerFrame>()
    private let discreteHub = BroadcastHub<PointerDiscreteEvent>()
    private let semanticHub = BroadcastHub<SemanticSnapshot>()
    private var inputObservers: [InputObserverSlot] = []
    private var isProcessingInputBatch = false
    private var deferredInputBatches: [PointerInputBatch] = []
    private var isDeliveringInput = false
    private var inputObserversNeedCompaction = false

    private var settledState = SettledPointerPolicyState()
    private var latestFrame: PointerFrame?
    private var latestSemantic: SemanticSnapshot?
    private var semanticTask: Task<Void, Never>?
    private var startTask: Task<StartReport, Never>?
    private var captureMode: PointerCaptureMode = .stopped
    private var lifecycle: Lifecycle = .stopped
    private var lifecycleToken: UInt64 = 0
    private var wantsToRun = false

    private static let maximumDeferredInputBatches = 8

    public init(configuration: PointerConfiguration = PointerConfiguration()) {
        self.configuration = configuration
        let mailbox = MotionMailbox()
        let discreteRing = DiscreteRing()
        let eventMetrics = EventMetrics()
        self.mailbox = mailbox
        self.discreteRing = discreteRing
        self.eventMetrics = eventMetrics
        pointerTap = PassivePointerTap(
            mailbox: mailbox,
            discreteRing: discreteRing,
            metrics: eventMetrics
        )
        semanticResolver = AXSemanticResolver(
            cacheLifetimeNs: configuration.semanticCacheLifetimeNs
        )
        overlay = HaloOverlayController(mailbox: mailbox, discreteRing: discreteRing)

        overlay.onInputBatch = { [weak self] batch in
            self?.accept(batch)
        }
    }

    public func start() async -> StartReport {
        wantsToRun = true

        switch lifecycle {
        case .running:
            return StartReport(
                captureMode: captureMode,
                permissions: permissionStatus(),
                started: true
            )
        case .starting:
            if let startTask {
                return await startTask.value
            }
        case .stopping:
            await pointerTap.stopAndWait()
            guard wantsToRun else {
                return stoppedReport()
            }
            if case .stopping = lifecycle {
                lifecycle = .stopped
            }
            // Another start may have arrived while the tap thread was winding down.
            // Re-enter through the state machine so every caller shares the same task.
            return await start()
        case .stopped:
            break
        }

        let permissions = permissionStatus()
        lifecycleToken &+= 1
        let token = lifecycleToken
        lifecycle = .starting
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return StartReport(
                    captureMode: .stopped,
                    permissions: permissions,
                    started: false
                )
            }
            return await self.performStart(token: token, permissions: permissions)
        }
        startTask = task
        let report = await task.value
        if lifecycleToken == token {
            startTask = nil
        }
        return report
    }

    /// Begins deterministic shutdown immediately, without waiting for the event-tap
    /// thread. App termination uses this synchronous half; normal callers should await
    /// `stop()` so transports are known to be producer-free before they are reused.
    public func requestStop() {
        wantsToRun = false
        lifecycleToken &+= 1
        startTask?.cancel()
        lifecycle = .stopping
        pointerTap.requestStop()
        tearDownPresentationAndSemantics()
    }

    public func stop() async {
        if case .stopped = lifecycle {
            wantsToRun = false
            return
        }

        let inFlightStart = startTask
        requestStop()
        await pointerTap.stopAndWait()
        _ = await inFlightStart?.value

        guard !wantsToRun else { return }
        startTask = nil
        lifecycle = .stopped
        captureMode = .stopped
    }

    private func performStart(
        token: UInt64,
        permissions: PermissionReport
    ) async -> StartReport {
        var selectedMode: PointerCaptureMode = .stopped
        if permissions.inputMonitoring == .granted {
            do {
                try await pointerTap.start()
                selectedMode = .eventTap
            } catch let error as PointerTapError {
                switch error {
                case .permissionDenied, .creationFailed:
                    selectedMode = configuration.allowPositionOnlyFallback
                        ? .positionOnly
                        : .stopped
                case .alreadyRunning, .startCancelled:
                    selectedMode = .stopped
                }
            } catch {
                selectedMode = .stopped
            }
        } else {
            selectedMode = configuration.allowPositionOnlyFallback ? .positionOnly : .stopped
        }

        guard !Task.isCancelled,
              wantsToRun,
              lifecycleToken == token,
              selectedMode != .stopped
        else {
            if selectedMode == .eventTap {
                pointerTap.requestStop()
                await pointerTap.stopAndWait()
            }
            if lifecycleToken == token {
                lifecycle = .stopped
                captureMode = .stopped
            }
            return StartReport(captureMode: .stopped, permissions: permissions, started: false)
        }

        captureMode = selectedMode
        settledState.reset()
        lifecycle = .running
        overlay.start(captureMode: selectedMode, reduceMotion: configuration.reduceMotion)
        guard wantsToRun, lifecycleToken == token, case .running = lifecycle else {
            return stoppedReport()
        }
        return StartReport(captureMode: selectedMode, permissions: permissions, started: true)
    }

    private func tearDownPresentationAndSemantics() {
        semanticTask?.cancel()
        semanticTask = nil
        overlay.stop()
        semanticResolver.invalidateSession()
        settledState.reset()
        deferredInputBatches.removeAll(keepingCapacity: false)
        latestFrame = nil
        latestSemantic = nil
        captureMode = .stopped
    }

    private func stoppedReport() -> StartReport {
        StartReport(
            captureMode: .stopped,
            permissions: permissionStatus(),
            started: false
        )
    }

    public func frames() -> AsyncStream<PointerFrame> {
        frameHub.stream(bufferingPolicy: .bufferingNewest(1))
    }

    public func discreteEvents() -> AsyncStream<PointerDiscreteEvent> {
        discreteHub.stream(bufferingPolicy: .bufferingNewest(128))
    }

    /// Registers a constant-time owner on the serial interaction lane.
    /// Delivery is synchronous on MainActor and never crosses an AsyncStream buffer,
    /// so discrete transitions cannot race or be dropped relative to their frame.
    public func observeOrderedInput(
        _ handler: @escaping (PointerInputEvent) -> Void
    ) -> PointerInputObservation {
        compactInputObserversIfNeeded()
        let observation = PointerInputObservation()
        inputObservers.append(InputObserverSlot(id: observation.id, handler: handler))
        return observation
    }

    public func removeInputObservation(_ observation: PointerInputObservation) {
        guard let index = inputObservers.firstIndex(where: { $0.id == observation.id }) else {
            return
        }
        inputObservers[index].handler = nil
        inputObserversNeedCompaction = true
        compactInputObserversIfNeeded()
    }

    public func semanticUpdates() -> AsyncStream<SemanticSnapshot> {
        semanticHub.stream(bufferingPolicy: .bufferingNewest(8))
    }

    public func currentFrame() -> PointerFrame? {
        _ = refreshPositionOnlyStateIfNeeded()
        return latestFrame
    }

    public func resolve(_ request: SemanticRequest) async -> SemanticSnapshot {
        _ = refreshPositionOnlyStateIfNeeded()
        let snapshot = await semanticResolver.resolve(request)
        _ = refreshPositionOnlyStateIfNeeded()
        // Historical point reads are valid for an explicitly pinned surface. `accept`
        // publishes only a snapshot that still matches current pointer generation.
        accept(snapshot)
        return snapshot
    }

    public func perform(_ request: SemanticActionRequest) async -> SemanticActionResult {
        // This method is deliberately never called by hover. A higher layer must issue an
        // explicit semantic action against a current, session-scoped target and generation.
        _ = refreshPositionOnlyStateIfNeeded()
        if captureMode == .positionOnly {
            // With the fallback renderer asleep there is no continuous generation clock.
            // Read-only context remains available, but side effects require the event tap.
            return SemanticActionResult(outcome: .rejected, failure: .unsupported)
        }
        guard case .running = lifecycle,
              latestFrame?.generation == request.expectedGeneration,
              latestSemantic?.state == .fresh,
              latestSemantic?.generation == request.expectedGeneration,
              latestSemantic?.target?.id == request.targetID
        else {
            return SemanticActionResult(outcome: .rejected, failure: .staleGeneration)
        }
        return await semanticResolver.perform(request)
    }

    public func present(_ scene: OverlayScene) throws {
        let physicallyCurrentFrame = refreshPositionOnlyStateIfNeeded()
        let nowNs = DispatchTime.now().uptimeNanoseconds
        try scene.validate(
            currentGeneration: physicallyCurrentFrame?.generation
                ?? latestFrame?.generation
                ?? 0,
            nowNs: nowNs
        )
        overlay.present(scene)
    }

    public func clearOverlay(expectedGeneration: UInt64? = nil) {
        var physicallyCurrentFrame: PointerFrame?
        if expectedGeneration != nil {
            physicallyCurrentFrame = refreshPositionOnlyStateIfNeeded()
        }
        if let expectedGeneration,
           let latestGeneration = physicallyCurrentFrame?.generation
               ?? latestFrame?.generation,
           expectedGeneration != latestGeneration
        {
            return
        }
        overlay.present(nil)
    }

    public func permissionStatus() -> PermissionReport {
        PermissionReport(
            inputMonitoring: PassivePointerTap.hasListenPermission() ? .granted : .denied,
            accessibility: AXPermissionController.hasPermission() ? .granted : .denied
        )
    }

    public func requestPermission(_ permission: PointerPermission) -> PermissionState {
        switch permission {
        case .inputMonitoring:
            _ = PassivePointerTap.requestListenPermission()
            return PassivePointerTap.hasListenPermission() ? .granted : .denied
        case .accessibility:
            _ = AXPermissionController.requestPermission()
            return AXPermissionController.hasPermission() ? .granted : .unknown
        }
    }

    public func health() -> HealthSnapshot {
        _ = refreshPositionOnlyStateIfNeeded()
        return HealthSnapshot(
            capturedAtNs: DispatchTime.now().uptimeNanoseconds,
            captureMode: captureMode,
            permissions: permissionStatus(),
            eventTap: eventMetrics.snapshot(),
            renderSubmitLatency: overlay.latencySummary(),
            latestGeneration: latestFrame?.generation ?? 0,
            latestSemanticState: latestSemantic?.state
        )
    }

    /// Position-only mode deliberately pauses its display link while no scene is visible.
    /// Refresh every public operation whose generation or point is safety-relevant so an
    /// old request cannot remain valid merely because the renderer is asleep.
    private func refreshPositionOnlyStateIfNeeded() -> PointerFrame? {
        guard captureMode == .positionOnly else { return latestFrame }
        return overlay.refreshPositionOnlyFrame()
    }

    private func accept(_ batch: PointerInputBatch) {
        if isProcessingInputBatch {
            enqueueDeferredInputBatch(batch)
            return
        }
        guard case .running = lifecycle else { return }

        isProcessingInputBatch = true
        var nextBatch: PointerInputBatch? = batch
        var processedBatchCount = 0
        while let currentBatch = nextBatch {
            let token = lifecycleToken
            guard process(currentBatch, lifecycleToken: token) else { break }
            processedBatchCount += 1
            if processedBatchCount >= Self.maximumDeferredInputBatches,
               !deferredInputBatches.isEmpty
            {
                let recoveryIndex = deferredInputBatches.lastIndex {
                    $0.frame != nil
                } ?? (deferredInputBatches.count - 1)
                var recoveryBatch = deferredInputBatches[recoveryIndex]
                recoveryBatch.resynchronization = .beforeBatch
                deferredInputBatches.removeAll(keepingCapacity: true)
                _ = process(
                    recoveryBatch,
                    lifecycleToken: token
                )
                // Recovery callbacks may themselves refresh position-only state. The
                // resync barrier already told gesture owners to discard candidates, so
                // reconcile the newest resulting frame without recursively notifying the
                // ordered lane again. This keeps Bedrock and Halo on the same generation.
                let newestNestedFrame = deferredInputBatches.reversed().lazy
                    .compactMap(\.frame)
                    .first
                deferredInputBatches.removeAll(keepingCapacity: true)
                if let newestNestedFrame,
                   isAcceptingInput(lifecycleToken: token)
                {
                    reconcileAfterInputOverflow(newestNestedFrame)
                }
                break
            }
            if !deferredInputBatches.isEmpty {
                nextBatch = deferredInputBatches.removeFirst()
            } else {
                nextBatch = nil
            }
        }
        deferredInputBatches.removeAll(keepingCapacity: true)
        isProcessingInputBatch = false
        compactInputObserversIfNeeded()
    }

    private func enqueueDeferredInputBatch(_ batch: PointerInputBatch) {
        let isFrameOnly = batch.frame != nil &&
            batch.discreteEvents.isEmpty &&
            batch.resynchronization == .none
        if isFrameOnly,
           let last = deferredInputBatches.last,
           last.frame != nil,
           last.discreteEvents.isEmpty,
           last.resynchronization == .none
        {
            deferredInputBatches[deferredInputBatches.count - 1] = batch
            return
        }
        guard deferredInputBatches.count < Self.maximumDeferredInputBatches else {
            // A synchronous observer is violating the constant-time contract. Preserve
            // bounded memory, discard uncertain ordering, and make the newest state begin
            // behind an explicit resynchronization barrier.
            var newest = batch
            newest.resynchronization = .beforeBatch
            deferredInputBatches.removeAll(keepingCapacity: true)
            deferredInputBatches.append(newest)
            return
        }
        deferredInputBatches.append(batch)
    }

    private func reconcileAfterInputOverflow(_ frame: PointerFrame) {
        latestFrame = frame
        latestSemantic = nil
        settledState.reset()
        semanticResolver.updateCurrentPointerFrame(
            generation: frame.generation,
            point: frame.coordinates.quartzGlobal
        )
        frameHub.yield(frame)
    }

    private func process(_ batch: PointerInputBatch, lifecycleToken token: UInt64) -> Bool {
        guard isAcceptingInput(lifecycleToken: token) else { return false }
        switch batch.resynchronization {
        case .none:
            return processOrdered(batch, lifecycleToken: token)
        case .beforeBatch:
            guard emitResynchronization(
                reference: batch.frame ?? latestFrame,
                lifecycleToken: token
            ) else { return false }
            return processOrdered(batch, lifecycleToken: token)
        case .transportRecovery:
            guard emitResynchronization(
                reference: batch.frame ?? latestFrame,
                lifecycleToken: token
            ) else { return false }
            if let frame = batch.frame {
                reconcileAfterInputOverflow(frame)
            }
            return isAcceptingInput(lifecycleToken: token)
        }
    }

    private func processOrdered(
        _ batch: PointerInputBatch,
        lifecycleToken token: UInt64
    ) -> Bool {
        guard let frame = batch.frame else {
            return accept(batch.discreteEvents[...], lifecycleToken: token)
        }
        let splitIndex = batch.discreteEvents.firstIndex {
            $0.sequence > frame.sequence
        } ?? batch.discreteEvents.endIndex
        guard accept(batch.discreteEvents[..<splitIndex], lifecycleToken: token) else {
            return false
        }
        guard accept(frame, lifecycleToken: token) else { return false }
        return accept(batch.discreteEvents[splitIndex...], lifecycleToken: token)
    }

    private func emitResynchronization(
        reference frame: PointerFrame?,
        lifecycleToken token: UInt64
    ) -> Bool {
        invalidateForDiscreteInput()
        publish(
            PointerDiscreteEvent(
                sequence: frame?.sequence ?? 0,
                eventTimestampNs: frame?.eventTimestampNs ?? 0,
                observedTimestampNs: frame?.observedTimestampNs ?? 0,
                point: frame?.coordinates.quartzGlobal ?? GlobalPoint(x: 0, y: 0),
                kind: .resynchronize,
                button: nil,
                buttons: frame?.buttons ?? [],
                modifiers: frame?.modifiers ?? []
            )
        )
        return isAcceptingInput(lifecycleToken: token)
    }

    private func accept(
        _ events: ArraySlice<PointerDiscreteEvent>,
        lifecycleToken token: UInt64
    ) -> Bool {
        guard !events.isEmpty else { return isAcceptingInput(lifecycleToken: token) }
        invalidateForDiscreteInput()
        for event in events {
            publish(event)
            guard isAcceptingInput(lifecycleToken: token) else { return false }
        }
        return true
    }

    private func invalidateForDiscreteInput() {
        semanticResolver.invalidateCache()
        latestSemantic = nil
        settledState.reset()
    }

    private func publish(_ event: PointerDiscreteEvent) {
        discreteHub.yield(event)
        deliver(.discrete(event))
    }

    private func accept(_ frame: PointerFrame, lifecycleToken token: UInt64) -> Bool {
        guard isAcceptingInput(lifecycleToken: token) else { return false }
        latestFrame = frame
        semanticResolver.updateCurrentPointerFrame(
            generation: frame.generation,
            point: frame.coordinates.quartzGlobal
        )
        frameHub.yield(frame)
        deliver(.frame(frame))
        guard isAcceptingInput(lifecycleToken: token) else { return false }

        let cachedTarget = latestSemantic?.target
        if let request = settledState.requestIfReady(
            frame: frame,
            policy: configuration.semanticPolicy,
            cachedTargetFrame: cachedTarget?.frame,
            cachedAtNs: latestSemantic?.capturedAtNs,
            cacheLifetimeNs: configuration.semanticCacheLifetimeNs
        ) {
            semanticTask = Task { [weak self, semanticResolver] in
                let snapshot = await semanticResolver.resolve(request)
                guard !Task.isCancelled else { return }
                self?.accept(snapshot)
            }
        }
        return true
    }

    private func isAcceptingInput(lifecycleToken token: UInt64) -> Bool {
        guard lifecycleToken == token, case .running = lifecycle else { return false }
        return true
    }

    private func deliver(_ input: PointerInputEvent) {
        isDeliveringInput = true
        for index in inputObservers.indices {
            inputObservers[index].handler?(input)
        }
        isDeliveringInput = false
        compactInputObserversIfNeeded()
    }

    private func compactInputObserversIfNeeded() {
        guard inputObserversNeedCompaction, !isDeliveringInput else { return }
        inputObservers.removeAll(where: { $0.handler == nil })
        inputObserversNeedCompaction = false
    }

    private func accept(_ snapshot: SemanticSnapshot) {
        guard snapshot.state != .superseded else { return }
        guard let latestFrame, snapshot.generation == latestFrame.generation else {
            return
        }

        latestSemantic = snapshot
        semanticHub.yield(snapshot)
    }
}
