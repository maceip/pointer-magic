@preconcurrency import AppKit
import PointerCore

/// A passive, click-through outline for the object frozen by Perception Lens.
/// It never participates in hit testing and never replaces or moves the system cursor.
@MainActor
final class PerceptionOutlineController {
    private let panel: NSPanel
    private let outline = PerceptionOutlineView()

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = outline
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.setAccessibilityElement(false)
    }

    func show(quartzFrame: GlobalRect, confidence: Double, inferred: Bool) {
        guard let appKitFrame = Self.appKitFrame(for: quartzFrame),
              appKitFrame.width >= 2,
              appKitFrame.height >= 2
        else {
            hide()
            return
        }

        outline.update(confidence: confidence, inferred: inferred)
        panel.setFrame(appKitFrame.insetBy(dx: -3, dy: -3), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private static func appKitFrame(for rect: GlobalRect) -> CGRect? {
        let quartzRect = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.intersects(quartzRect) else { continue }

            return CGRect(
                x: screen.frame.minX + quartzRect.minX - displayBounds.minX,
                y: screen.frame.minY + screen.frame.height
                    - (quartzRect.maxY - displayBounds.minY),
                width: quartzRect.width,
                height: quartzRect.height
            )
        }
        return nil
    }
}

@MainActor
private final class PerceptionOutlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 2
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(confidence: Double, inferred: Bool) {
        let color = inferred ? NSColor.systemOrange : NSColor.systemPurple
        let alpha = 0.55 + min(max(confidence, 0), 1) * 0.4
        layer?.borderColor = color.withAlphaComponent(alpha).cgColor
        layer?.backgroundColor = color.withAlphaComponent(0.055).cgColor
    }
}
