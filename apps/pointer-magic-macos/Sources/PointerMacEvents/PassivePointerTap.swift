@preconcurrency import ApplicationServices
import Foundation
import PointerCore
import PointerTransport

public enum PointerTapError: Error, Equatable, Sendable {
    case alreadyRunning
    case permissionDenied
    case creationFailed
    case startCancelled
}

/// A passive global pointer tap with a deliberately tiny callback.
///
/// The callback copies primitive values into fixed-size transport structures. It never
/// performs accessibility work, calls clients, logs, allocates an NSEvent, suppresses an
/// event, or synchronously touches the main thread.
public final class PassivePointerTap: @unchecked Sendable {
    public let mailbox: MotionMailbox
    public let discreteRing: DiscreteRing
    public let metrics: EventMetrics

    private let worker: TapWorker

    public init(
        mailbox: MotionMailbox,
        discreteRing: DiscreteRing,
        metrics: EventMetrics
    ) {
        self.mailbox = mailbox
        self.discreteRing = discreteRing
        self.metrics = metrics
        worker = TapWorker(mailbox: mailbox, discreteRing: discreteRing, metrics: metrics)
    }

    deinit {
        // The worker is retained by its temporary event thread, not vice versa. Requesting
        // stop here therefore lets the run loop exit without a tap-owner retain cycle.
        worker.requestStop()
    }

    public static func hasListenPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestListenPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    public func start() async throws {
        try await worker.start()
    }

    public func requestStop() {
        worker.requestStop()
    }

    public func stopAndWait() async {
        await worker.stopAndWait()
    }
}

private final class TapWorker: @unchecked Sendable {
    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
    }

    private let mailbox: MotionMailbox
    private let discreteRing: DiscreteRing
    private let metrics: EventMetrics

    private let lifecycleLock = NSLock()
    private var lifecycle: Lifecycle = .idle
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    // Event-thread confined.
    private var session: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pressedButtons: UInt32 = 0
    private var interactionModifierTracker = PointerInteractionModifierTracker(
        initialState: []
    )

    init(mailbox: MotionMailbox, discreteRing: DiscreteRing, metrics: EventMetrics) {
        self.mailbox = mailbox
        self.discreteRing = discreteRing
        self.metrics = metrics
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            lifecycleLock.lock()
            guard lifecycle == .idle else {
                lifecycleLock.unlock()
                continuation.resume(throwing: PointerTapError.alreadyRunning)
                return
            }
            lifecycle = .starting
            lifecycleLock.unlock()

            let thread = Thread { [self] in
                runTapThread(startContinuation: continuation)
            }
            thread.name = "PointerMagic.CGEventTap"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    func requestStop() {
        lifecycleLock.lock()
        guard lifecycle != .idle else {
            lifecycleLock.unlock()
            return
        }
        lifecycle = .stopping
        let activeRunLoop = runLoop
        lifecycleLock.unlock()

        if let activeRunLoop {
            CFRunLoopStop(activeRunLoop)
            CFRunLoopWakeUp(activeRunLoop)
        }
    }

    func stopAndWait() async {
        requestStop()
        await withCheckedContinuation { continuation in
            lifecycleLock.lock()
            if lifecycle == .idle {
                lifecycleLock.unlock()
                continuation.resume()
            } else {
                stopWaiters.append(continuation)
                lifecycleLock.unlock()
            }
        }
    }

    private func runTapThread(
        startContinuation: CheckedContinuation<Void, any Error>
    ) {
        autoreleasepool {
            session &+= 1
            sequence = session << 48
            pressedButtons = physicalButtonState()
            interactionModifierTracker.rebase(to: PhysicalModifierMonitor.currentExactState())
            mailbox.reset()
            discreteRing.reset()

            let interestedEvents: [CGEventType] = [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .leftMouseDown,
                .leftMouseUp,
                .rightMouseDown,
                .rightMouseUp,
                .otherMouseDown,
                .otherMouseUp,
                .scrollWheel,
                .flagsChanged,
            ]
            let mask = interestedEvents.reduce(CGEventMask(0)) { partial, type in
                partial | (CGEventMask(1) << type.rawValue)
            }

            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let worker = Unmanaged<TapWorker>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return worker.handle(type: type, event: event)
            }

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                finishStart(
                    continuation: startContinuation,
                    error: PassivePointerTap.hasListenPermission()
                        ? .creationFailed
                        : .permissionDenied
                )
                return
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                finishStart(continuation: startContinuation, error: .creationFailed)
                return
            }

            let currentRunLoop = CFRunLoopGetCurrent()
            lifecycleLock.lock()
            let wasCancelled = lifecycle == .stopping
            self.tap = tap
            self.source = source
            runLoop = currentRunLoop
            if !wasCancelled {
                lifecycle = .running
            }
            lifecycleLock.unlock()

            guard !wasCancelled else {
                startContinuation.resume(throwing: PointerTapError.startCancelled)
                finishThread()
                return
            }

            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            startContinuation.resume()

            lifecycleLock.lock()
            let shouldRun = lifecycle == .running
            lifecycleLock.unlock()
            if shouldRun {
                CFRunLoopRun()
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(currentRunLoop, source, .commonModes)
            finishThread()
        }
    }

    private func finishStart(
        continuation: CheckedContinuation<Void, any Error>,
        error: PointerTapError
    ) {
        continuation.resume(throwing: error)
        finishThread()
    }

    private func finishThread() {
        // No producer is active beyond this point, so transport reset cannot race a write.
        mailbox.reset()
        discreteRing.reset()

        lifecycleLock.lock()
        tap = nil
        source = nil
        runLoop = nil
        lifecycle = .idle
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: false)
        lifecycleLock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            metrics.recordTapDisabledByTimeout()
            resynchronizeAfterTapInterruption(event: event)
            reenableTap()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            metrics.recordTapDisabledByUserInput()
            resynchronizeAfterTapInterruption(event: event)
            reenableTap()
            return Unmanaged.passUnretained(event)
        }

        let callbackStartedNs = MonotonicClock.nowNs()
        defer {
            metrics.recordCallback(durationNs: MonotonicClock.nowNs() &- callbackStartedNs)
        }

        sequence &+= 1
        let observedNs = callbackStartedNs
        let quartzPoint = event.location
        let appKitPoint = event.unflippedLocation
        let modifiers = event.flags.rawValue

        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == 61 || keyCode == 54 else { break }
            let transitions = interactionModifierTracker.update(
                to: PhysicalModifierMonitor.currentExactState()
            )
            for transition in transitions {
                emitModifier(
                    transition,
                    event: event,
                    quartzPoint: quartzPoint,
                    modifiers: modifiers,
                    observedNs: observedNs
                )
            }
        case .leftMouseDown:
            pressedButtons |= PointerButtonMask.primary.rawValue
            emitButton(
                event: event,
                kind: .buttonDown,
                button: .primary,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .leftMouseUp:
            pressedButtons &= ~PointerButtonMask.primary.rawValue
            emitButton(
                event: event,
                kind: .buttonUp,
                button: .primary,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .rightMouseDown:
            pressedButtons |= PointerButtonMask.secondary.rawValue
            emitButton(
                event: event,
                kind: .buttonDown,
                button: .secondary,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .rightMouseUp:
            pressedButtons &= ~PointerButtonMask.secondary.rawValue
            emitButton(
                event: event,
                kind: .buttonUp,
                button: .secondary,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .otherMouseDown:
            let button = otherButton(for: event)
            pressedButtons |= mask(for: button)
            emitButton(
                event: event,
                kind: .buttonDown,
                button: button,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .otherMouseUp:
            let button = otherButton(for: event)
            pressedButtons &= ~mask(for: button)
            emitButton(
                event: event,
                kind: .buttonUp,
                button: button,
                quartzPoint: quartzPoint,
                modifiers: modifiers,
                observedNs: observedNs
            )
        case .scrollWheel:
            let discrete = PointerDiscreteEvent(
                sequence: sequence,
                eventTimestampNs: event.timestamp,
                observedTimestampNs: observedNs,
                point: GlobalPoint(x: quartzPoint.x, y: quartzPoint.y),
                kind: .scroll,
                button: nil,
                buttons: PointerButtonMask(rawValue: pressedButtons),
                modifiers: PointerModifierFlags(rawValue: modifiers),
                scrollDelta: GlobalPoint(
                    x: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                    y: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
                )
            )
            if !discreteRing.push(discrete) {
                metrics.recordDiscreteOverflow()
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            writeMotion(
                event: event,
                quartzPoint: quartzPoint,
                appKitPoint: appKitPoint,
                modifiers: modifiers,
                observedNs: observedNs,
                kind: .dragged
            )
        case .mouseMoved:
            writeMotion(
                event: event,
                quartzPoint: quartzPoint,
                appKitPoint: appKitPoint,
                modifiers: modifiers,
                observedNs: observedNs,
                kind: .moved
            )
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func emitButton(
        event: CGEvent,
        kind: PointerDiscreteKind,
        button: PointerButton,
        quartzPoint: CGPoint,
        modifiers: UInt64,
        observedNs: UInt64
    ) {
        let discrete = PointerDiscreteEvent(
            sequence: sequence,
            eventTimestampNs: event.timestamp,
            observedTimestampNs: observedNs,
            point: GlobalPoint(x: quartzPoint.x, y: quartzPoint.y),
            kind: kind,
            button: button,
            buttons: PointerButtonMask(rawValue: pressedButtons),
            modifiers: PointerModifierFlags(rawValue: modifiers),
            clickCount: Int(event.getIntegerValueField(.mouseEventClickState))
        )
        if !discreteRing.push(discrete) {
            metrics.recordDiscreteOverflow()
        }

        writeMotion(
            event: event,
            quartzPoint: quartzPoint,
            appKitPoint: event.unflippedLocation,
            modifiers: modifiers,
            observedNs: observedNs,
            kind: .button
        )
    }

    private func emitModifier(
        _ transition: PointerInteractionModifierTransition,
        event: CGEvent,
        quartzPoint: CGPoint,
        modifiers: UInt64,
        observedNs: UInt64
    ) {
        let discrete = PointerDiscreteEvent(
            sequence: sequence,
            eventTimestampNs: event.timestamp,
            observedTimestampNs: observedNs,
            point: GlobalPoint(x: quartzPoint.x, y: quartzPoint.y),
            kind: PointerDiscreteKind(transition),
            button: nil,
            buttons: PointerButtonMask(rawValue: pressedButtons),
            modifiers: PointerModifierFlags(rawValue: modifiers)
        )
        if !discreteRing.push(discrete) {
            metrics.recordDiscreteOverflow()
        }
    }

    private func writeMotion(
        event: CGEvent,
        quartzPoint: CGPoint,
        appKitPoint: CGPoint,
        modifiers: UInt64,
        observedNs: UInt64,
        kind: PointerEventKind
    ) {
        mailbox.write(
            TransportMotionSample(
                sequence: sequence,
                eventTimestampNs: event.timestamp,
                observedTimestampNs: observedNs,
                coordinates: PointerCoordinates(
                    quartzGlobal: GlobalPoint(x: quartzPoint.x, y: quartzPoint.y),
                    appKitGlobal: GlobalPoint(x: appKitPoint.x, y: appKitPoint.y)
                ),
                flags: modifiers,
                buttons: pressedButtons,
                kind: kind
            )
        )
    }

    private func reenableTap() {
        lifecycleLock.lock()
        let currentTap = tap
        let shouldEnable = lifecycle == .running
        lifecycleLock.unlock()
        if shouldEnable, let currentTap {
            CGEvent.tapEnable(tap: currentTap, enable: true)
        }
    }

    private func resynchronizeAfterTapInterruption(event: CGEvent) {
        sequence &+= 1
        pressedButtons = physicalButtonState()
        interactionModifierTracker.rebase(to: PhysicalModifierMonitor.currentExactState())
        let nowNs = MonotonicClock.nowNs()
        let point = event.location
        let resynchronize = PointerDiscreteEvent(
            sequence: sequence,
            eventTimestampNs: event.timestamp,
            observedTimestampNs: nowNs,
            point: GlobalPoint(x: point.x, y: point.y),
            kind: .resynchronize,
            button: nil,
            buttons: PointerButtonMask(rawValue: pressedButtons),
            modifiers: PointerModifierFlags(rawValue: event.flags.rawValue)
        )
        if !discreteRing.push(resynchronize) {
            metrics.recordDiscreteOverflow()
        }
    }

    private func physicalButtonState() -> UInt32 {
        var result: UInt32 = 0
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            result |= PointerButtonMask.primary.rawValue
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) {
            result |= PointerButtonMask.secondary.rawValue
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .center) {
            result |= PointerButtonMask.middle.rawValue
        }
        return result
    }

    private func otherButton(for event: CGEvent) -> PointerButton {
        let raw = event.getIntegerValueField(.mouseEventButtonNumber)
        return raw == 2 ? .middle : .other
    }

    private func mask(for button: PointerButton) -> UInt32 {
        switch button {
        case .primary: PointerButtonMask.primary.rawValue
        case .secondary: PointerButtonMask.secondary.rawValue
        case .middle: PointerButtonMask.middle.rawValue
        case .other: PointerButtonMask.other.rawValue
        }
    }
}
