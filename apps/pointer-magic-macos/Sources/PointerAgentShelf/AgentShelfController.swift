@preconcurrency import AppKit
import PointerCore
import PointerShelfContracts
import QuartzCore

/// Owns the read-only shelf that follows, but never replaces, the system cursor.
///
/// Motion preferably arrives from the shared bedrock pointer clock via
/// `acceptPointerSample`. A low-duty MainActor timer keeps corner-restore dwell
/// and park recognition alive when the pointer is stationary or Input Monitoring
/// is unavailable.
@MainActor
public final class AgentShelfController: NSObject {
    private enum Disclosure {
        case iconOnly
        case currentShelf

        var fraction: CGFloat {
            switch self {
            case .iconOnly: 0
            case .currentShelf: 1
            }
        }
    }

    private struct DisclosureMorph {
        let startedAtNs: UInt64
        let durationNs: UInt64
        let fromFraction: CGFloat
        let toFraction: CGFloat
    }

    public private(set) var isRunning = false
    public private(set) var isVisible = false
    public private(set) var isLockedForInteraction = false
    public private(set) var isMorphingPresentation = false
    public var onClick: (() -> Void)?
    public var onAction: ((String) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onParkRequested: (() -> Bool)?
    public var onReleaseRequested: (() -> Bool)?
    public var onFollowerRestoreRequested: (() -> Bool)?
    public var onInteractionExpired: (() -> Void)?

    private let shelfView: AgentShelfView
    private let panel: AgentShelfPanel
    private var presentation: ShelfDocument?
    private var armingTimer: Timer?
    private var activeScreen: NSScreen?
    private var lastPointerLocation: CGPoint?
    private var needsPositionUpdate = false
    private var interactionStateOverride: String?
    private var interactionExpiryTask: Task<Void, Never>?
    private var revealExpiryTask: Task<Void, Never>?
    private var parkingGesture = AgentShelfParkingGesture()
    private var cornerRestoreGesture = AgentShelfCornerRestoreGesture()
    private var disclosure: Disclosure = .currentShelf
    private var disclosureMorph: DisclosureMorph?
    private var lastExternalSampleAtNs: UInt64 = 0
    private var currentArmingInterval: TimeInterval = 0
    private var interactionLeaseSuspended = false

    private static let interactionLeaseNanoseconds: UInt64 = 8_000_000_000
    private static let updateRevealNanoseconds: UInt64 = 5_000_000_000
    private static let disclosureMorphNanoseconds: UInt64 = 220_000_000
    private static let externalSampleFreshnessNs: UInt64 = 100_000_000
    private static let lowDutyInterval: TimeInterval = 1.0 / 15.0
    private static let highDutyInterval: TimeInterval = 1.0 / 60.0

    public override init() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 30))
        shelfView = view
        panel = AgentShelfPanel(contentView: view)
        super.init()

        view.onClick = { [weak self] in
            guard let self, self.isLockedForInteraction else { return }
            self.onClick?()
        }
        view.onAction = { [weak self] actionID in
            guard let self, self.isLockedForInteraction else { return }
            self.onAction?(actionID)
        }
        view.onDismiss = { [weak self] in
            guard let self, self.isLockedForInteraction else { return }
            self.onDismiss?()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastPointerLocation = nil
        parkingGesture.reset()
        cornerRestoreGesture.reset()
        needsPositionUpdate = true
        activeScreen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        rescheduleArmingTimer()
        if isVisible {
            positionAndOrderFront(force: true)
        }
    }

    public func stop() {
        guard isRunning else { return }
        hide()
        isRunning = false
        armingTimer?.invalidate()
        armingTimer = nil
        currentArmingInterval = 0
        activeScreen = nil
        lastPointerLocation = nil
        lastExternalSampleAtNs = 0
        parkingGesture.reset()
        cornerRestoreGesture.reset()
        cancelRevealLease()
        cancelDisclosureMorph()
    }

    /// Consumes a sample from the shared bedrock pointer clock. Constant-time:
    /// layout only runs when the follower is visible or a gesture fires.
    public func acceptPointerSample(appKitPoint: CGPoint, timestampNs: UInt64) {
        guard isRunning else { return }
        lastExternalSampleAtNs = timestampNs
        processSample(pointer: appKitPoint, timestampNs: timestampNs)
        rescheduleArmingTimer()
    }

    /// Presents a new value immediately. Empty values are treated as an explicit hide.
    public func show(
        _ presentation: ShelfDocument,
        significance: AgentShelfUpdateSignificance = .meaningful
    ) {
        guard !presentation.isEmpty else {
            hide()
            return
        }
        if !isRunning {
            start()
        }
        self.presentation = presentation
        applyPresentation(presentation)
        isVisible = true
        if significance == .meaningful {
            revealMeaningfulUpdate()
        } else {
            setDisclosure(.iconOnly, animated: false)
        }
        needsPositionUpdate = true
        positionAndOrderFront(force: true)
        rescheduleArmingTimer()
    }

    public func show(
        _ presentation: AgentShelfPresentation,
        significance: AgentShelfUpdateSignificance = .meaningful
    ) {
        show(presentation.asShelfDocument(id: "legacy"), significance: significance)
    }

    /// Replaces the currently presented value without changing visibility.
    public func update(
        _ presentation: ShelfDocument,
        significance: AgentShelfUpdateSignificance = .passive
    ) {
        guard !presentation.isEmpty else {
            hide()
            return
        }
        if presentation != self.presentation {
            self.presentation = presentation
            applyPresentation(presentation)
            needsPositionUpdate = true
        }
        if significance == .meaningful {
            revealMeaningfulUpdate()
        }
        if needsPositionUpdate, isVisible, isRunning {
            positionAndOrderFront(force: true)
        }
        rescheduleArmingTimer()
    }

    public func update(
        _ presentation: AgentShelfPresentation,
        significance: AgentShelfUpdateSignificance = .passive
    ) {
        update(presentation.asShelfDocument(id: "legacy"), significance: significance)
    }

    /// Freezes the shelf at its current screen position and allows it to receive clicks.
    /// The panel remains nonactivating and cannot become key or main.
    public func lockForInteraction() {
        guard isRunning, isVisible else { return }
        guard !isLockedForInteraction else { return }
        cancelRevealLease()
        setDisclosure(.currentShelf, animated: false)
        placeFollower(at: NSEvent.mouseLocation)
        // Ensure the panel is on-screen before arming hits. A follower that was
        // briefly ordered out would otherwise silently refuse to lock.
        panel.orderFrontRegardless()
        setInteractionLocked(true)
        scheduleInteractionExpiry()
        rescheduleArmingTimer()
    }

    /// Replaces only the parked shelf's state line. Background updates keep
    /// updating the retained base presentation, but cannot hide an action result.
    public func showInteractionStatus(_ status: String) {
        guard isLockedForInteraction, let presentation else { return }
        interactionStateOverride = status
        applyPresentation(presentation)
        scheduleInteractionExpiry()
    }

    /// Extends the parked interaction lease without changing the visible status.
    public func refreshInteractionLease() {
        guard isLockedForInteraction, !interactionLeaseSuspended else { return }
        scheduleInteractionExpiry()
    }

    /// Holds the park lease while an explicit activation is in flight so a slow
    /// Automation prompt cannot unlock the shelf underneath the handoff.
    public func suspendInteractionLease() {
        interactionLeaseSuspended = true
        interactionExpiryTask?.cancel()
        interactionExpiryTask = nil
    }

    public func resumeInteractionLease() {
        interactionLeaseSuspended = false
        guard isLockedForInteraction else { return }
        scheduleInteractionExpiry()
    }

    /// Restores the normal click-through follower behavior.
    public func unlockInteraction() {
        interactionLeaseSuspended = false
        let wasLocked = isLockedForInteraction
        setInteractionLocked(false)
        guard wasLocked, isRunning, isVisible else {
            rescheduleArmingTimer()
            return
        }
        setDisclosure(.iconOnly, animated: true)
        lastPointerLocation = nil
        needsPositionUpdate = true
        positionAndOrderFront(force: true)
        rescheduleArmingTimer()
    }

    public func hide() {
        isVisible = false
        setInteractionLocked(false)
        cancelRevealLease()
        cancelDisclosureMorph()
        disclosure = .iconOnly
        _ = shelfView.setDisclosureFraction(0)
        presentation = nil
        parkingGesture.reset()
        cornerRestoreGesture.reset()
        panel.orderOut(nil)
        rescheduleArmingTimer()
    }

    @objc
    private func armingTimerFired(_ timer: Timer) {
        guard isRunning else { return }
        let timestampNs = DispatchTime.now().uptimeNanoseconds
        if hasFreshExternalSample(at: timestampNs),
           !isMorphingPresentation,
           !needsPolledGestureTick(at: timestampNs)
        {
            // External samples already drove follow/park; only advance morph here.
            advanceDisclosureMorph(at: timestampNs)
            return
        }
        processSample(pointer: NSEvent.mouseLocation, timestampNs: timestampNs)
    }

    @objc
    private func screenParametersChanged() {
        guard isRunning else { return }
        if isLockedForInteraction {
            expireInteraction()
        }
        activeScreen = nil
        lastPointerLocation = nil
        parkingGesture.reset()
        cornerRestoreGesture.reset()
        needsPositionUpdate = true
        activeScreen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        if isVisible {
            positionAndOrderFront(force: true)
        }
        rescheduleArmingTimer()
    }

    @objc
    private func accessibilityDisplayOptionsChanged() {
        shelfView.refreshAccessibilityAppearance()
    }

    private func processSample(pointer: CGPoint, timestampNs: UInt64) {
        let pointerScreen = screen(containing: pointer) ?? NSScreen.main
        observeCornerRestoreGesture(
            at: pointer,
            on: pointerScreen,
            timestampNs: timestampNs
        )
        observeParkingGesture(at: pointer, timestampNs: timestampNs)
        advanceDisclosureMorph(at: timestampNs)
        guard isVisible else { return }
        positionAndOrderFront(force: false, pointer: pointer)
    }

    private func positionAndOrderFront(force: Bool, pointer sampledPointer: CGPoint? = nil) {
        guard let presentation, !presentation.isEmpty else {
            hide()
            return
        }
        guard !isLockedForInteraction else {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            return
        }

        let pointer = sampledPointer ?? NSEvent.mouseLocation
        guard force || needsPositionUpdate || pointer != lastPointerLocation else { return }
        guard let pointerScreen = screen(containing: pointer) ?? NSScreen.main else {
            panel.orderOut(nil)
            return
        }

        if pointerScreen !== activeScreen {
            activeScreen = pointerScreen
        }

        placeFollower(at: pointer, on: pointerScreen)
    }

    private func applyPresentation(_ presentation: ShelfDocument) {
        let frozenOrigin = panel.frame.origin
        let size = shelfView.apply(presentationWithInteractionState(presentation))
        if isLockedForInteraction {
            panel.setFrame(
                CGRect(origin: frozenOrigin, size: size),
                display: false
            )
        } else {
            panel.setContentSize(size)
        }
    }

    private func setInteractionLocked(_ locked: Bool) {
        if !locked {
            interactionExpiryTask?.cancel()
            interactionExpiryTask = nil
            interactionStateOverride = nil
        }
        isLockedForInteraction = locked
        panel.ignoresMouseEvents = !locked
        // Rise above the full-screen Halo companion (same .statusBar tier) so
        // parked clicks hit this panel instead of falling through empty overlay
        // chrome ordered later at the same level.
        panel.level = locked ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
            : .statusBar
        shelfView.setInteractionLocked(locked)
        if locked {
            // Parked interaction owns the pointer. Release is ✦ / menu only so a
            // trailing wiggle or aim motion cannot steal the click target.
            parkingGesture.clearCandidatePreservingCooldown(
                at: DispatchTime.now().uptimeNanoseconds
            )
            syncPanelContentFrame()
            panel.orderFrontRegardless()
        } else {
            parkingGesture.reset()
        }
        if !locked, let presentation {
            applyPresentation(presentation)
        }
    }

    private func observeParkingGesture(at pointer: CGPoint, timestampNs: UInt64) {
        // While parked, never interpret motion as release. The person is aiming
        // a click at the shelf; ✦ / menu remains the explicit unlock path.
        guard !isLockedForInteraction else { return }
        let buttonsArePressed = NSEvent.pressedMouseButtons != 0
        guard parkingGesture.observe(
            point: pointer,
            timestampNs: timestampNs,
            buttonsArePressed: buttonsArePressed
        ) else { return }
        _ = onParkRequested?()
    }

    private func syncPanelContentFrame() {
        guard let content = panel.contentView else { return }
        let bounds = panel.contentLayoutRect
        content.frame = CGRect(origin: .zero, size: bounds.size)
        shelfView.frame = content.bounds
        shelfView.needsLayout = true
        shelfView.layoutSubtreeIfNeeded()
    }

    private func observeCornerRestoreGesture(
        at pointer: CGPoint,
        on pointerScreen: NSScreen?,
        timestampNs: UInt64
    ) {
        guard let pointerScreen,
              let screenNumber = pointerScreen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else {
            cornerRestoreGesture.reset()
            return
        }
        let shouldRestore = cornerRestoreGesture.observe(
            point: pointer,
            screenIdentifier: screenNumber.uint32Value,
            screenFrame: pointerScreen.frame,
            timestampNs: timestampNs,
            buttonsArePressed: NSEvent.pressedMouseButtons != 0
        )
        guard shouldRestore,
              isLockedForInteraction || !isVisible
        else { return }
        _ = onFollowerRestoreRequested?()
    }

    private func presentationWithInteractionState(
        _ presentation: ShelfDocument
    ) -> ShelfDocument {
        guard let interactionStateOverride else { return presentation }
        if var fallback = presentation.fallback {
            fallback = ShelfCompactFallback(
                provider: fallback.provider,
                state: interactionStateOverride,
                directoryName: fallback.directoryName,
                providerMark: fallback.providerMark
            )
            return ShelfDocument(
                id: presentation.id,
                providerId: presentation.providerId,
                revision: presentation.revision,
                contextRevision: presentation.contextRevision,
                ttlMs: presentation.ttlMs,
                primary: presentation.primary,
                actions: presentation.actions,
                fallback: fallback
            )
        }
        if var primary = presentation.primary {
            primary = ShelfPrimaryCard(
                chips: primary.chips,
                prompt: ShelfPromptSlot(placeholder: interactionStateOverride),
                accessories: primary.accessories
            )
            return ShelfDocument(
                id: presentation.id,
                providerId: presentation.providerId,
                revision: presentation.revision,
                contextRevision: presentation.contextRevision,
                ttlMs: presentation.ttlMs,
                primary: primary,
                actions: presentation.actions,
                fallback: presentation.fallback
            )
        }
        return presentation
    }

    private func placeFollower(at pointer: CGPoint, on knownScreen: NSScreen? = nil) {
        guard let pointerScreen = knownScreen ?? screen(containing: pointer) ?? NSScreen.main else {
            return
        }
        if pointerScreen !== activeScreen {
            activeScreen = pointerScreen
        }
        let targetFrame = AgentShelfPlacement.frame(
            pointer: pointer,
            screenFrame: pointerScreen.frame,
            shelfSize: shelfView.frame.size
        )
        panel.setFrame(targetFrame, display: false)
        if isVisible, !panel.isVisible {
            panel.orderFrontRegardless()
        }
        lastPointerLocation = pointer
        needsPositionUpdate = false
    }

    private func scheduleInteractionExpiry() {
        interactionExpiryTask?.cancel()
        guard !interactionLeaseSuspended else { return }
        interactionExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.interactionLeaseNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.isLockedForInteraction,
                  !self.interactionLeaseSuspended
            else { return }
            self.expireInteraction()
        }
    }

    private func revealMeaningfulUpdate() {
        guard !isLockedForInteraction else {
            setDisclosure(.currentShelf, animated: false)
            return
        }
        setDisclosure(.currentShelf, animated: true)
        revealExpiryTask?.cancel()
        revealExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.updateRevealNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.isRunning,
                  self.isVisible,
                  !self.isLockedForInteraction
            else { return }
            self.revealExpiryTask = nil
            self.setDisclosure(.iconOnly, animated: true)
        }
    }

    private func setDisclosure(_ target: Disclosure, animated: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        advanceDisclosureMorph(at: now)
        disclosureMorph = nil
        isMorphingPresentation = false

        let fromFraction = shelfView.renderedDisclosureFraction
        disclosure = target
        let shouldAnimate = animated &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            abs(fromFraction - target.fraction) > 0.001 &&
            isRunning && isVisible

        if shouldAnimate {
            disclosureMorph = DisclosureMorph(
                startedAtNs: now,
                durationNs: Self.disclosureMorphNanoseconds,
                fromFraction: fromFraction,
                toFraction: target.fraction
            )
            isMorphingPresentation = true
            needsPositionUpdate = true
            rescheduleArmingTimer()
            return
        }

        let targetSize = shelfView.setDisclosureFraction(target.fraction)
        panel.setContentSize(targetSize)
        needsPositionUpdate = true
        if isRunning, isVisible, !isLockedForInteraction {
            positionAndOrderFront(force: true)
        }
        rescheduleArmingTimer()
    }

    private func advanceDisclosureMorph(at timestampNs: UInt64) {
        guard let morph = disclosureMorph else { return }
        guard timestampNs >= morph.startedAtNs else {
            cancelDisclosureMorph()
            return
        }

        let elapsedNs = timestampNs - morph.startedAtNs
        let linearProgress = min(
            1,
            CGFloat(elapsedNs) / CGFloat(max(1, morph.durationNs))
        )
        let easedProgress = linearProgress * linearProgress * (3 - (2 * linearProgress))
        let fraction = morph.fromFraction +
            ((morph.toFraction - morph.fromFraction) * easedProgress)
        let size = shelfView.setDisclosureFraction(fraction)
        panel.setContentSize(size)
        needsPositionUpdate = true

        if linearProgress >= 1 {
            disclosureMorph = nil
            isMorphingPresentation = false
            _ = shelfView.setDisclosureFraction(disclosure.fraction)
            rescheduleArmingTimer()
        }
    }

    private func cancelRevealLease() {
        revealExpiryTask?.cancel()
        revealExpiryTask = nil
    }

    private func cancelDisclosureMorph() {
        disclosureMorph = nil
        isMorphingPresentation = false
    }

    private func expireInteraction() {
        guard isLockedForInteraction else { return }
        unlockInteraction()
        onInteractionExpired?()
    }

    private func hasFreshExternalSample(at timestampNs: UInt64) -> Bool {
        guard lastExternalSampleAtNs > 0, timestampNs >= lastExternalSampleAtNs else {
            return false
        }
        return timestampNs - lastExternalSampleAtNs < Self.externalSampleFreshnessNs
    }

    private func needsPolledGestureTick(at _: UInt64) -> Bool {
        // Corner restore advances while the pointer is stationary in a corner.
        // Park recognition ignores idle ticks, but restore must keep sampling time.
        isLockedForInteraction || !isVisible || isMorphingPresentation
    }

    private func preferredArmingInterval(at timestampNs: UInt64) -> TimeInterval {
        let needsSmoothFollow = isVisible && !isLockedForInteraction
        let externalCoversFollow = hasFreshExternalSample(at: timestampNs)
        if isMorphingPresentation {
            return Self.highDutyInterval
        }
        if needsSmoothFollow, !externalCoversFollow {
            return Self.highDutyInterval
        }
        return Self.lowDutyInterval
    }

    private func rescheduleArmingTimer() {
        guard isRunning else {
            armingTimer?.invalidate()
            armingTimer = nil
            currentArmingInterval = 0
            return
        }
        let interval = preferredArmingInterval(at: DispatchTime.now().uptimeNanoseconds)
        if armingTimer != nil, abs(interval - currentArmingInterval) < 0.000_5 {
            return
        }
        armingTimer?.invalidate()
        currentArmingInterval = interval
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(armingTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        armingTimer = timer
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
    }
}
