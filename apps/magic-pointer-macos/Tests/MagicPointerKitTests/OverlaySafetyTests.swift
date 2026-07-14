@preconcurrency import AppKit
@testable import PointerMacOverlay
import Testing

@Suite("Overlay safety")
@MainActor
struct OverlaySafetyTests {
    @Test("The AppKit panel cannot take pointer or keyboard ownership")
    func panelIsPassive() throws {
        let screen = try #require(NSScreen.main)
        let content = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        let panel = OverlayPanel(screen: screen, contentView: content)

        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isOpaque)
        #expect(panel.hidesOnDeactivate == false)
        #expect(panel.isAccessibilityElement() == false)
        panel.close()
    }

    @Test(
        "The companion never enters the cursor exclusion area",
        arguments: [
            CGPoint(x: 20, y: 20),
            CGPoint(x: 780, y: 20),
            CGPoint(x: 20, y: 580),
            CGPoint(x: 780, y: 580),
            CGPoint(x: 400, y: 300),
        ],
        [false, true]
    )
    func cursorExclusion(pointer: CGPoint, expanded: Bool) {
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
        let center = CompanionPlacement.center(
            for: pointer,
            inside: canvas,
            expanded: expanded
        )
        let cluster = CompanionPlacement.clusterRect(center: center, expanded: expanded)
        let protected = CompanionPlacement.protectedCursorRect(at: pointer)

        #expect(!cluster.intersects(protected))
        #expect(canvas.contains(cluster))
    }
}
