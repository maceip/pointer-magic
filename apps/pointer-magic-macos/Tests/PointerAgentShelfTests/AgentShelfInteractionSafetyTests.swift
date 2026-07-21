@preconcurrency import AppKit
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf interaction safety")
@MainActor
struct AgentShelfInteractionSafetyTests {
    @Test("Receiving a click never makes the shelf panel key or main")
    func interactivePanelRemainsNonactivating() {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 64))
        let panel = AgentShelfPanel(contentView: content)

        #expect(panel.ignoresMouseEvents)
        panel.ignoresMouseEvents = false
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isKeyWindow)
        #expect(!panel.isMainWindow)
        panel.close()
    }

    @Test("A hidden shelf cannot be accidentally armed for interaction")
    func hiddenShelfDoesNotLock() {
        let controller = AgentShelfController()

        controller.lockForInteraction()

        #expect(!controller.isLockedForInteraction)
        controller.stop()
    }

    @Test("The deliberate first click is accepted without taking first responder")
    func firstClickIsDeliveredWithoutKeyboardFocus() {
        let view = AgentShelfView(frame: CGRect(x: 0, y: 0, width: 240, height: 64))

        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.acceptsFirstResponder)
    }
}
