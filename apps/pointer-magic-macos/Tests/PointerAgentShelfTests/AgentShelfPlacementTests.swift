import CoreGraphics
import PointerCore
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf placement")
struct AgentShelfPlacementTests {
    private let screen = CGRect(x: -800, y: 0, width: 800, height: 600)
    private let shelf = CGSize(width: 300, height: 74)

    @Test("The normal shelf is below and close to the real cursor")
    func ordinaryPlacement() {
        let pointer = CGPoint(x: -400, y: 300)
        let frame = AgentShelfPlacement.frame(
            pointer: pointer,
            screenFrame: screen,
            shelfSize: shelf
        )

        #expect(frame.maxY == 263)
        expectCursorSafe(frame, pointer: pointer)
    }

    @Test(
        "Screen corners remain cursor-safe",
        arguments: [
            CGPoint(x: -788, y: 12),
            CGPoint(x: -12, y: 12),
            CGPoint(x: -788, y: 588),
            CGPoint(x: -12, y: 588),
        ]
    )
    func corners(pointer: CGPoint) {
        let frame = AgentShelfPlacement.frame(
            pointer: pointer,
            screenFrame: screen,
            shelfSize: shelf
        )
        expectCursorSafe(frame, pointer: pointer)
        #expect(screen.contains(frame))
    }

    private func expectCursorSafe(_ frame: CGRect, pointer: CGPoint) {
        let protected = PointerCompanionLayout.protectedCursorRect(
            at: GlobalPoint(x: pointer.x, y: pointer.y)
        )
        let protectedFrame = CGRect(
            x: protected.minX,
            y: protected.minY,
            width: protected.size.width,
            height: protected.size.height
        )
        #expect(!frame.intersects(protectedFrame))
    }
}
