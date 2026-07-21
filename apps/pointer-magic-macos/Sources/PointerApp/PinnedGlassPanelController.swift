@preconcurrency import AppKit
import PointerCore

/// A small, pinned panel that deliberately separates its collapsed invitation
/// from its latched, interactive state.
///
/// This controller is intentionally standalone. It does not observe global
/// pointer events, hide the system cursor, perform semantic lookup, or call a
/// model. A future owner supplies those behaviors through the closures below.
@MainActor
final class PinnedGlassPanelController: NSObject {
    enum State: Equatable {
        case collapsed
        case expanded(context: String)
        case perceptionLens
    }

    struct Metrics {
        static let collapsedSize = NSSize(width: 200, height: 38)
        static let expandedSize = NSSize(width: 340, height: 132)
        static let perceptionLensSize = NSSize(width: 488, height: 324)
        static let anchorGap: CGFloat = 5
        static let screenMargin: CGFloat = 10
        static let collapsedCornerRadius: CGFloat = 19
        static let expandedCornerRadius: CGFloat = 22
    }

    /// Called only when the pointer enters the panel while it is collapsed.
    var onPointerEntered: (() -> Void)?

    /// Called by the plainly labelled “Follow pointer” button.
    var onFollowPointer: (() -> Void)?

    /// Reports the stable candidate index selected in the Perception Lens.
    var onCandidateChanged: ((Int) -> Void)?

    /// Records one explicit assessment without closing or changing the sample.
    var onFeedback: ((PerceptionFeedbackKind) -> Void)?

    /// A frozen sample is invalid once display geometry changes.
    var onScreenParametersChanged: (() -> Void)?

    /// Called by the “Close” button before the panel is hidden.
    var onClose: (() -> Void)?

    private(set) var state: State = .collapsed

    private let panel: PinnedInteractivePanel
    private let contentView = PinnedPanelContentView()
    private var pinnedFrame: CGRect?
    private var pinnedPlacement: PointerCompanionPlacement = .below
    private var surfaceView: NSView?

    init(
        collapsedLabel: String = "Pointer Magic ready",
        onPointerEntered: (() -> Void)? = nil,
        onFollowPointer: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onPointerEntered = onPointerEntered
        self.onFollowPointer = onFollowPointer
        self.onClose = onClose

        panel = PinnedInteractivePanel(
            contentRect: NSRect(origin: .zero, size: Metrics.collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        contentView.collapsedLabel.stringValue = collapsedLabel
        contentView.onPointerEntered = { [weak self] in
            guard let self, self.state == .collapsed else { return }
            self.onPointerEntered?()
        }
        contentView.followButton.target = self
        contentView.followButton.action = #selector(followPointerPressed)
        contentView.closeButton.target = self
        contentView.closeButton.action = #selector(closePressed)
        contentView.onCandidateChanged = { [weak self] index in
            self?.onCandidateChanged?(index)
        }
        contentView.onFeedback = { [weak self] feedback in
            self?.onFeedback?(feedback)
        }
        contentView.onTryAnother = { [weak self] in
            self?.followPointerPressed()
        }
        contentView.onLensClose = { [weak self] in
            self?.closePressed()
        }
        panel.onEscape = { [weak self] in
            self?.closePressed()
        }
        panel.onPreviousCandidate = { [weak contentView] in
            contentView?.selectPreviousCandidate()
        }
        panel.onNextCandidate = { [weak contentView] in
            contentView?.selectNextCandidate()
        }

        configurePanel()
        installSurface(for: .collapsed)
        apply(state: .collapsed, animated: false)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Replaces the click-through follower at its exact frame. Keeping the shared
    /// placement side prevents a bottom-edge follower from jumping through the cursor.
    func showPinned(
        frame: CGRect,
        placement: PointerCompanionPlacement,
        label: String? = nil
    ) {
        pinnedFrame = frame
        pinnedPlacement = placement
        if let label {
            contentView.collapsedLabel.stringValue = label
        }
        apply(state: .collapsed, animated: false)
        panel.orderFrontRegardless()
    }

    /// Latches the panel open at its current anchor and reveals context plus
    /// the two interactive controls. The panel does not follow the pointer by
    /// itself; the owner decides what “Follow pointer” means.
    func expand(context: String) {
        apply(state: .expanded(context: context), animated: true)
        // NEVER make the panel key or set a first responder — that steals the
        // user's typing (see PinnedInteractivePanel.canBecomeKey). Buttons are
        // clicked by mouse on this nonactivating panel without keyboard focus.
        panel.orderFrontRegardless()
    }

    /// Freezes the panel into the Perception Lens. Later enrichment updates its
    /// fields in place so the glass, frame, candidate ordering, and focus stay stable.
    func showPerceptionLens(_ model: PerceptionLensViewModel) {
        contentView.showPerceptionLens(model)
        apply(state: .perceptionLens, animated: true)
        // Never key / never first-responder — same input invariant as expand().
        panel.orderFrontRegardless()
    }

    func updatePerceptionLens(_ model: PerceptionLensViewModel) {
        guard state == .perceptionLens else {
            showPerceptionLens(model)
            return
        }
        contentView.updatePerceptionLens(model)
    }

    func setFeedbackStatus(recorded: Bool) {
        guard state == .perceptionLens else { return }
        contentView.setFeedbackStatus(recorded: recorded)
    }

    /// Returns to the modest, pinned invitation state.
    func collapse(label: String? = nil) {
        if let label {
            contentView.collapsedLabel.stringValue = label
        }
        apply(state: .collapsed, animated: true)
    }

    func hide() {
        if panel.isKeyWindow {
            panel.resignKey()
        }
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var frame: CGRect {
        panel.frame
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Match the passive overlay's level so the exact-frame handoff cannot disappear
        // behind the Dock or another ordinary app window.
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .utilityWindow
    }

    private func apply(state newState: State, animated: Bool) {
        state = newState
        panel.candidateNavigationEnabled = newState == .perceptionLens

        let size: NSSize
        let cornerRadius: CGFloat
        switch newState {
        case .collapsed:
            size = Metrics.collapsedSize
            cornerRadius = Metrics.collapsedCornerRadius
            contentView.showCollapsed()
        case let .expanded(context):
            size = Metrics.expandedSize
            cornerRadius = Metrics.expandedCornerRadius
            contentView.showExpanded(context: context)
        case .perceptionLens:
            size = Metrics.perceptionLensSize
            cornerRadius = Metrics.expandedCornerRadius
            contentView.showPerceptionLensContainer()
        }

        installSurface(for: newState, cornerRadius: cornerRadius)
        resizeAndPin(to: size, animated: animated)
    }

    private func resizeAndPin(to size: NSSize, animated: Bool) {
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.minSize = size
        panel.maxSize = size

        let reference = pinnedFrame ?? panel.frame
        let targetFrame = Self.frame(
            size: size,
            alignedTo: reference,
            placement: pinnedPlacement
        )
        if animated {
            panel.animator().setFrame(targetFrame, display: true)
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func installSurface(for state: State, cornerRadius: CGFloat? = nil) {
        let radius = cornerRadius ?? {
            switch state {
            case .collapsed: Metrics.collapsedCornerRadius
            case .expanded, .perceptionLens: Metrics.expandedCornerRadius
            }
        }()

        contentView.removeFromSuperview()
        surfaceView?.removeFromSuperview()

        let surface = PinnedPanelSurfaceFactory.makeSurface(
            contentView: contentView,
            cornerRadius: radius
        )
        surface.frame = NSRect(origin: .zero, size: panel.frame.size)
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        surfaceView = surface
    }

    private static func frame(
        size: NSSize,
        alignedTo reference: CGRect,
        placement: PointerCompanionPlacement,
        preserveExactSize: Bool = true
    ) -> NSRect {
        if preserveExactSize,
           abs(size.width - reference.width) < 0.1,
           abs(size.height - reference.height) < 0.1
        {
            return reference
        }

        var frame: CGRect
        switch placement {
        case .below:
            frame = CGRect(
                x: reference.midX - size.width / 2,
                y: reference.maxY - size.height,
                width: size.width,
                height: size.height
            )
        case .above:
            frame = CGRect(
                x: reference.midX - size.width / 2,
                y: reference.minY,
                width: size.width,
                height: size.height
            )
        case .right:
            frame = CGRect(
                x: reference.minX,
                y: reference.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .left:
            frame = CGRect(
                x: reference.maxX - size.width,
                y: reference.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(reference) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame.insetBy(
            dx: Metrics.screenMargin,
            dy: Metrics.screenMargin
        ) else { return frame }

        let maximumX = max(visibleFrame.maxX - size.width, visibleFrame.minX)
        let maximumY = max(visibleFrame.maxY - size.height, visibleFrame.minY)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), maximumX)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), maximumY)
        return frame
    }

    @objc
    private func followPointerPressed() {
        onFollowPointer?()
    }

    @objc
    private func closePressed() {
        onClose?()
        hide()
    }

    @objc
    private func accessibilityDisplayOptionsChanged() {
        // Just rebuild the glass surface. The panel never holds keyboard focus
        // (canBecomeKey == false), so there is nothing to restore, and nothing
        // here may grab the user's keys.
        installSurface(for: state)
    }

    @objc
    private func screenParametersChanged() {
        guard panel.isVisible else { return }
        if state == .perceptionLens {
            onScreenParametersChanged?()
            return
        }

        // The stored frame is the collapsed follower's exact handoff geometry. Reconcile
        // that canonical anchor first so later expand/collapse transitions cannot jump back
        // toward a display that was disconnected or rearranged.
        let reference = pinnedFrame ?? panel.frame
        pinnedFrame = Self.frame(
            size: Metrics.collapsedSize,
            alignedTo: reference,
            placement: pinnedPlacement,
            preserveExactSize: false
        )

        let size: NSSize = switch state {
        case .collapsed: Metrics.collapsedSize
        case .expanded: Metrics.expandedSize
        case .perceptionLens: Metrics.perceptionLensSize
        }
        resizeAndPin(to: size, animated: false)
    }
}

@MainActor
private final class PinnedInteractivePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onPreviousCandidate: (() -> Void)?
    var onNextCandidate: (() -> Void)?
    var candidateNavigationEnabled = false

    // HARD INVARIANT: this panel must NEVER take keyboard focus. A
    // nonactivating panel that becomes key routes the user's typing into
    // itself — that ate keystrokes in a demo. canBecomeKey == false makes it
    // physically impossible for the window server to deliver keys here; the
    // buttons stay clickable by mouse (content view acceptsFirstMouse). With
    // the listen-only event tap, halo never takes custody of input, so a hang
    // or crash cannot hold or drop it.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard candidateNavigationEnabled,
              !(firstResponder is NSPopUpButton)
        else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.keyCode {
        case 123:
            onPreviousCandidate?()
            return true
        case 124:
            onNextCandidate?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

@MainActor
private final class PinnedPanelContentView: NSView {
    let collapsedLabel = NSTextField(labelWithString: "")
    let contextLabel = NSTextField(wrappingLabelWithString: "")
    let followButton = NSButton(title: "Follow pointer", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)

    var onCandidateChanged: ((Int) -> Void)?
    var onFeedback: ((PerceptionFeedbackKind) -> Void)?
    var onTryAnother: (() -> Void)?
    var onLensClose: (() -> Void)?

    var perceptionPrimaryButton: NSButton { perceptionLensView.rightObjectButton }

    var onPointerEntered: (() -> Void)?

    private let collapsedContainer = NSView()
    private let expandedContainer = NSView()
    private let perceptionLensView = PerceptionLensContentView()
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        configureCollapsedContent()
        configureExpandedContent()
        configurePerceptionLens()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pointer Magic panel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func showCollapsed() {
        collapsedContainer.isHidden = false
        expandedContainer.isHidden = true
        perceptionLensView.isHidden = true
    }

    func showExpanded(context: String) {
        contextLabel.stringValue = context
        collapsedContainer.isHidden = true
        expandedContainer.isHidden = false
        perceptionLensView.isHidden = true
    }

    func showPerceptionLens(_ model: PerceptionLensViewModel) {
        perceptionLensView.update(model)
        showPerceptionLensContainer()
    }

    func updatePerceptionLens(_ model: PerceptionLensViewModel) {
        perceptionLensView.update(model)
    }

    func setFeedbackStatus(recorded: Bool) {
        perceptionLensView.setFeedbackStatus(recorded: recorded)
    }

    func showPerceptionLensContainer() {
        collapsedContainer.isHidden = true
        expandedContainer.isHidden = true
        perceptionLensView.isHidden = false
    }

    func selectPreviousCandidate() {
        guard !perceptionLensView.isHidden else { return }
        perceptionLensView.selectPrevious()
    }

    func selectNextCandidate() {
        guard !perceptionLensView.isHidden else { return }
        perceptionLensView.selectNext()
    }

    private func configureCollapsedContent() {
        collapsedContainer.translatesAutoresizingMaskIntoConstraints = false
        collapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        collapsedLabel.font = .systemFont(ofSize: 14, weight: .medium)
        collapsedLabel.textColor = .labelColor
        collapsedLabel.alignment = .center
        collapsedLabel.lineBreakMode = .byTruncatingTail
        collapsedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(collapsedContainer)
        collapsedContainer.addSubview(collapsedLabel)

        NSLayoutConstraint.activate([
            collapsedContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            collapsedContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsedContainer.topAnchor.constraint(equalTo: topAnchor),
            collapsedContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            collapsedLabel.leadingAnchor.constraint(equalTo: collapsedContainer.leadingAnchor, constant: 18),
            collapsedLabel.trailingAnchor.constraint(equalTo: collapsedContainer.trailingAnchor, constant: -18),
            collapsedLabel.centerYAnchor.constraint(equalTo: collapsedContainer.centerYAnchor),
        ])
    }

    private func configureExpandedContent() {
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        contextLabel.font = .systemFont(ofSize: 14, weight: .medium)
        contextLabel.textColor = .labelColor
        contextLabel.maximumNumberOfLines = 2
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        followButton.bezelStyle = .rounded
        followButton.controlSize = .regular
        followButton.setAccessibilityLabel("Follow pointer")
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .regular
        closeButton.setAccessibilityLabel("Close")
        followButton.nextKeyView = closeButton
        closeButton.nextKeyView = followButton

        let buttonRow = NSStackView(views: [followButton, closeButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 10

        expandedContainer.addSubview(contextLabel)
        expandedContainer.addSubview(buttonRow)
        addSubview(expandedContainer)

        NSLayoutConstraint.activate([
            expandedContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            expandedContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedContainer.topAnchor.constraint(equalTo: topAnchor),
            expandedContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contextLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 18),
            contextLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -18),
            contextLabel.topAnchor.constraint(equalTo: expandedContainer.topAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor, constant: -16),
            buttonRow.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func configurePerceptionLens() {
        perceptionLensView.translatesAutoresizingMaskIntoConstraints = false
        perceptionLensView.isHidden = true
        perceptionLensView.onCandidateChanged = { [weak self] index in
            self?.onCandidateChanged?(index)
        }
        perceptionLensView.onFeedback = { [weak self] feedback in
            self?.onFeedback?(feedback)
        }
        perceptionLensView.onTryAnother = { [weak self] in
            self?.onTryAnother?()
        }
        perceptionLensView.onClose = { [weak self] in
            self?.onLensClose?()
        }
        addSubview(perceptionLensView)
        NSLayoutConstraint.activate([
            perceptionLensView.leadingAnchor.constraint(equalTo: leadingAnchor),
            perceptionLensView.trailingAnchor.constraint(equalTo: trailingAnchor),
            perceptionLensView.topAnchor.constraint(equalTo: topAnchor),
            perceptionLensView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private enum PinnedPanelSurfaceFactory {
    static func makeSurface(contentView: NSView, cornerRadius: CGFloat) -> NSView {
        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldReduceTransparency ||
            workspace.accessibilityDisplayShouldIncreaseContrast
        {
            return PinnedSolidSurface(contentView: contentView, cornerRadius: cornerRadius)
        }

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = cornerRadius
            glassView.tintColor = NSColor.controlBackgroundColor.withAlphaComponent(0.08)
            glassView.contentView = contentView
            glassView.setAccessibilityElement(false)
            constrain(contentView, to: glassView)
            return glassView
        }

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = false
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true
        effectView.setAccessibilityElement(false)
        pin(contentView, inside: effectView)
        return effectView
    }

    private static func pin(_ contentView: NSView, inside host: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(contentView)
        constrain(contentView, to: host)
    }

    private static func constrain(_ contentView: NSView, to host: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: host.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

@MainActor
private final class PinnedSolidSurface: NSView {
    private let cornerRadius: CGFloat

    init(contentView: NSView, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
    }
}
