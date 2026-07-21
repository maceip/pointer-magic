@preconcurrency import AppKit

@MainActor
final class AgentShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentView: NSView) {
        super.init(
            contentRect: CGRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        setAccessibilityElement(false)
    }

    override func makeKey() {}
    override func makeMain() {}
}
