@preconcurrency import CoreGraphics
import Foundation

/// Bounded, local-only perception for the area around a Quartz-global pointer point.
///
/// The entry point only locks small scheduling state and enqueues work. Screen capture,
/// PNG encoding, OCR, classification, and foreground analysis never execute on the
/// caller's executor or on a pointer event-tap thread. At most one analysis is active;
/// when callers outrun it, only the newest pending request is retained.
public final class VisualPerceptionEngine: @unchecked Sendable {
    private final class Work: @unchecked Sendable {
        let request: VisualPerceptionRequest
        let requestedAtNs: UInt64
        private let continuation: CheckedContinuation<VisualPerceptionResult, Never>
        private let lock = NSLock()
        private var completed = false

        init(
            request: VisualPerceptionRequest,
            requestedAtNs: UInt64,
            continuation: CheckedContinuation<VisualPerceptionResult, Never>
        ) {
            self.request = request
            self.requestedAtNs = requestedAtNs
            self.continuation = continuation
        }

        var shouldAbort: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        @discardableResult
        func complete(_ result: VisualPerceptionResult) -> Bool {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return false
            }
            completed = true
            lock.unlock()
            continuation.resume(returning: result)
            return true
        }
    }

    private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        private var wasCancelled = false

        func install(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            if wasCancelled {
                lock.unlock()
                action()
            } else {
                self.action = action
                lock.unlock()
            }
        }

        func cancel() {
            lock.lock()
            wasCancelled = true
            let action = action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private let stateLock = NSLock()
    private var current: Work?
    private var pending: Work?

    private let workerQueue: OperationQueue
    private let capture = ScreenRegionCapture()

    public init() {
        let queue = OperationQueue()
        queue.name = "PointerMagic.VisualPerception"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        workerQueue = queue
    }

    deinit {
        cancelAll()
        workerQueue.cancelAllOperations()
    }

    /// Returns immediately to the cooperative executor after scheduling background work.
    /// This method never prompts for Screen Recording permission.
    public func analyze(_ request: VisualPerceptionRequest) async -> VisualPerceptionResult {
        let registration = CancellationRegistration()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Work(
                    request: request,
                    requestedAtNs: DispatchTime.now().uptimeNanoseconds,
                    continuation: continuation
                )
                registration.install { [weak self, weak work] in
                    guard let self, let work else { return }
                    self.cancel(work)
                }
                enqueue(work)
            }
        } onCancel: {
            registration.cancel()
        }
    }

    /// Cancels publication and prevents Vision work from starting for every owned request.
    /// ScreenCaptureKit does not expose cancellation for an in-flight screenshot, so that
    /// callback is discarded and a watchdog guarantees the queue cannot remain wedged.
    public func cancelAll() {
        stateLock.lock()
        let current = current
        let pending = pending
        self.pending = nil
        stateLock.unlock()

        if let current { cancel(current) }
        if let pending { cancel(pending) }
    }

    private func enqueue(_ work: Work) {
        guard !work.shouldAbort else { return }
        var replaced: Work?
        var shouldLaunch = false

        stateLock.lock()
        if current != nil {
            replaced = pending
            pending = work
        } else {
            current = work
            shouldLaunch = true
        }
        stateLock.unlock()

        if let replaced {
            _ = replaced.complete(terminalResult(for: replaced, failure: .superseded))
        }
        if shouldLaunch {
            launch(work)
        }
    }

    private func cancel(_ work: Work) {
        _ = work.complete(terminalResult(for: work, failure: .cancelled))
        var wasPending = false
        stateLock.lock()
        if pending === work {
            pending = nil
            wasPending = true
        }
        stateLock.unlock()
        if !wasPending {
            // Logical ownership moves immediately. Any late ScreenCaptureKit callback
            // sees the completed token and is discarded without publishing or running
            // further Vision stages.
            finishAndLaunchNext(completing: work)
        }
    }

    /// Cheap preflight only. Permission prompting must be owned by explicit application UI.
    public static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Invoke only from explicit user-facing permission UI; macOS may show a system prompt.
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private func launch(_ work: Work) {
        scheduleWatchdog(for: work)
        workerQueue.addOperation { [self] in
            guard !work.shouldAbort else {
                finishAndLaunchNext(completing: work)
                return
            }

            let captureCenter = work.request.cropCenter ?? work.request.point
            let point = CGPoint(x: captureCenter.x, y: captureCenter.y)
            let size = CGSize(
                width: work.request.cropSizePoints.width,
                height: work.request.cropSizePoints.height
            )
            capture.capture(
                point: point,
                requestedSize: size,
                excludeCurrentApplication: work.request.excludeCurrentApplication
            ) { [self] outcome in
                workerQueue.addOperation { [self] in
                    guard !work.shouldAbort else {
                        finishAndLaunchNext(completing: work)
                        return
                    }
                    let result = autoreleasepool {
                        makeResult(for: work, captureOutcome: outcome)
                    }
                    _ = work.complete(result)
                    finishAndLaunchNext(completing: work)
                }
            }
        }
    }

    private func scheduleWatchdog(for work: Work) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .seconds(2)
        ) { [weak self, weak work] in
            guard let self, let work else { return }
            _ = work.complete(self.terminalResult(for: work, failure: .captureFailed))
            self.finishAndLaunchNext(completing: work)
        }
    }

    private func makeResult(
        for work: Work,
        captureOutcome: RegionCaptureOutcome
    ) -> VisualPerceptionResult {
        switch captureOutcome {
        case let .failure(failure, message):
            let completedAt = DispatchTime.now().uptimeNanoseconds
            return VisualPerceptionResult(
                generation: work.request.generation,
                requestedAtNs: work.requestedAtNs,
                completedAtNs: completedAt,
                state: failure == .screenRecordingPermissionDenied ? .unavailable : .failed,
                failure: failure,
                diagnostics: [PerceptionDiagnostic(stage: .capture, message: message)]
            )

        case let .success(capture):
            let analyzed = VisionImageAnalyzer.analyze(
                capture: capture,
                request: work.request,
                shouldCancel: { work.shouldAbort }
            )
            let completedAt = DispatchTime.now().uptimeNanoseconds
            let rect = capture.globalRect
            let crop = PerceptionCropMetadata(
                globalRect: PerceptionRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: rect.height
                ),
                pointer: work.request.point,
                pixelWidth: capture.image.width,
                pixelHeight: capture.image.height,
                pixelsPerPointX: Double(capture.image.width) / max(rect.width, 1),
                pixelsPerPointY: Double(capture.image.height) / max(rect.height, 1),
                capturePath: capture.path
            )
            let visionFailures = analyzed.diagnostics.filter {
                $0.stage == .textRecognition ||
                    $0.stage == .imageClassification ||
                    $0.stage == .foregroundSegmentation
            }
            let requestedVisionStageCount = 1 +
                (work.request.includeImageClassifications ? 1 : 0) +
                (work.request.includeForegroundSummary ? 1 : 0)
            let cropEncodingFailed = work.request.includeCropPNG && analyzed.png == nil
            let state: VisualPerceptionState =
                visionFailures.isEmpty && !cropEncodingFailed ? .fresh : .partial
            return VisualPerceptionResult(
                generation: work.request.generation,
                requestedAtNs: work.requestedAtNs,
                completedAtNs: completedAt,
                state: state,
                failure: visionFailures.count == requestedVisionStageCount ? .visionFailed : nil,
                crop: crop,
                cropPNG: analyzed.png,
                textObservations: analyzed.text,
                imageClassifications: analyzed.classifications,
                foreground: analyzed.foreground,
                diagnostics: analyzed.diagnostics
            )
        }
    }

    private func finishAndLaunchNext(completing work: Work) {
        var next: Work?
        stateLock.lock()
        guard current === work else {
            stateLock.unlock()
            return
        }
        if let pending {
            next = pending
            self.pending = nil
            current = pending
        } else {
            current = nil
        }
        stateLock.unlock()

        if let next {
            launch(next)
        }
    }

    private func terminalResult(
        for work: Work,
        failure: VisualPerceptionFailure
    ) -> VisualPerceptionResult {
        let completedAt = DispatchTime.now().uptimeNanoseconds
        return VisualPerceptionResult(
            generation: work.request.generation,
            requestedAtNs: work.requestedAtNs,
            completedAtNs: completedAt,
            state: failure == .superseded ? .superseded : .failed,
            failure: failure
        )
    }
}
