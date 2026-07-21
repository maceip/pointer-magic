@preconcurrency import AppKit
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf dismissal")
@MainActor
struct AgentShelfDismissalTests {
    private let presentation = AgentShelfPresentation(
        provider: "Codex",
        state: "Working",
        directoryName: "webagent-ui"
    )

    @Test("Locking reveals dismissal without changing the compact shelf geometry")
    func lockingKeepsSizeStable() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 58))
        let unlockedSize = view.apply(presentation)

        #expect(unlockedSize.height == 30)
        #expect(!view.isDismissAffordanceVisible)
        view.setInteractionLocked(true)
        view.layoutSubtreeIfNeeded()

        #expect(view.isDismissAffordanceVisible)
        #expect(view.frame.size == unlockedSize)
        #expect(view.renderedStateTextColor == NSColor.controlAccentColor)
        #expect(!view.acceptsFirstResponder)
        #expect(view.dismissHitFrame.maxX <= view.bounds.maxX - 10)

        view.setInteractionLocked(false)
        #expect(view.renderedStateTextColor == NSColor.labelColor)
    }

    @Test("Body and dismissal clicks remain distinct while locked")
    func clickRouting() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 220, height: 58))
        _ = view.apply(presentation)
        var bodyClicks = 0
        var dismissClicks = 0
        view.onClick = { bodyClicks += 1 }
        view.onDismiss = { dismissClicks += 1 }
        view.setInteractionLocked(true)
        view.layoutSubtreeIfNeeded()

        view.routePrimaryClick(at: CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 5))
        view.routePrimaryClick(at: CGPoint(
            x: view.dismissHitFrame.midX,
            y: view.dismissHitFrame.midY
        ))

        #expect(bodyClicks == 1)
        #expect(dismissClicks == 1)

        view.setInteractionLocked(false)
        view.routePrimaryClick(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        #expect(bodyClicks == 1)
        #expect(dismissClicks == 1)
    }
}
