@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import PointerCore

/// Samples only the two physical right-side modifier keys used to arm pointer UI.
///
/// `CGEventSourceKeyState` reads the current Quartz source-state table; it does not
/// install a keyboard event listener or retain typed input. The monitor is used by
/// position-only capture, where a denied event tap must not make the shelf impossible
/// to interact with.
public final class PhysicalModifierMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (PointerInteractionModifierTransition) -> Void

    private let queue = DispatchQueue(
        label: "PointerMagic.PhysicalModifierMonitor",
        qos: .userInteractive
    )
    private let lifecycleLock = NSLock()
    private let stateProvider: @Sendable () -> PointerInteractionModifierState
    private var timer: DispatchSourceTimer?
    private var handler: Handler?
    private var tracker: PointerInteractionModifierTracker?
    private var lifecycleGeneration: UInt64 = 0

    public convenience init() {
        self.init(stateProvider: Self.currentPositionOnlyState)
    }

    init(
        stateProvider: @escaping @Sendable () -> PointerInteractionModifierState
    ) {
        self.stateProvider = stateProvider
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping Handler) {
        lifecycleLock.lock()
        guard timer == nil else {
            lifecycleLock.unlock()
            return
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        self.handler = handler
        tracker = PointerInteractionModifierTracker(initialState: stateProvider())

        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lifecycleLock.unlock()

        timer.setEventHandler { [weak self] in
            self?.poll(generation: generation)
        }
        // 240 Hz keeps the worst-case sampling delay near four milliseconds while
        // doing only two constant-time Quartz state reads per tick.
        timer.schedule(
            deadline: .now() + .milliseconds(4),
            repeating: .nanoseconds(4_166_667),
            leeway: .microseconds(250)
        )
        timer.activate()
    }

    public func stop() {
        lifecycleLock.lock()
        lifecycleGeneration &+= 1
        let timer = self.timer
        self.timer = nil
        handler = nil
        tracker = nil
        lifecycleLock.unlock()
        timer?.cancel()
    }

    /// Exact side-specific state available to the privileged event-tap lane.
    public static func currentExactState() -> PointerInteractionModifierState {
        var state: PointerInteractionModifierState = []
        if CGEventSource.keyState(.combinedSessionState, key: 61) {
            state.insert(.rightOption)
        }
        if CGEventSource.keyState(.combinedSessionState, key: 54) {
            state.insert(.rightCommand)
        }
        return state
    }

    /// Side-specific state for the permission-free position-only lane.
    ///
    /// `NSEvent.modifierFlags` is explicitly independent of event-stream delivery.
    /// Its public device-dependent bits preserve left/right identity, so this does
    /// not widen the clutch to ordinary left-side Command or Option shortcuts.
    public static func currentPositionOnlyState() -> PointerInteractionModifierState {
        state(deviceModifierFlags: NSEvent.modifierFlags.rawValue)
    }

    static func state(deviceModifierFlags rawValue: UInt) -> PointerInteractionModifierState {
        // Public IOLLEvent.h device-dependent modifier masks.
        let rightCommandMask: UInt = 0x0000_0010
        let rightOptionMask: UInt = 0x0000_0040
        var state: PointerInteractionModifierState = []
        if rawValue & rightOptionMask != 0 {
            state.insert(.rightOption)
        }
        if rawValue & rightCommandMask != 0 {
            state.insert(.rightCommand)
        }
        return state
    }

    private func poll(generation: UInt64) {
        let nextState = stateProvider()

        lifecycleLock.lock()
        guard generation == lifecycleGeneration,
              var tracker,
              let handler
        else {
            lifecycleLock.unlock()
            return
        }
        let transitions = tracker.update(to: nextState)
        self.tracker = tracker
        lifecycleLock.unlock()

        for transition in transitions {
            handler(transition)
        }
    }
}
