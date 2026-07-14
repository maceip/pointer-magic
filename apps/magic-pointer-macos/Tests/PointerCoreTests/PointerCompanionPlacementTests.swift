import PointerCore
import Testing

@Suite("Pointer companion placement")
struct PointerCompanionPlacementTests {
    private let canvas = GlobalRect(x: 0, y: 0, width: 800, height: 600)
    private let pill = GlobalSize(width: 200, height: 38)

    @Test("The ordinary placement is close and below")
    func ordinaryPlacementIsBelow() {
        let result = PointerCompanionLayout.place(
            pointer: GlobalPoint(x: 400, y: 300),
            inside: canvas,
            size: pill
        )

        #expect(result.placement == .below)
        #expect(result.frame.maxY == 263)
        expectSafe(result, pointer: GlobalPoint(x: 400, y: 300))
    }

    @Test("The pill flips above near the bottom edge")
    func bottomEdgeFlipsAbove() {
        let pointer = GlobalPoint(x: 400, y: 20)
        let result = PointerCompanionLayout.place(
            pointer: pointer,
            inside: canvas,
            size: pill
        )

        #expect(result.placement == .above)
        expectSafe(result, pointer: pointer)
    }

    @Test(
        "Every display corner preserves the real cursor",
        arguments: [
            GlobalPoint(x: 12, y: 12),
            GlobalPoint(x: 788, y: 12),
            GlobalPoint(x: 12, y: 588),
            GlobalPoint(x: 788, y: 588),
        ]
    )
    func cornersStaySafe(pointer: GlobalPoint) {
        let result = PointerCompanionLayout.place(
            pointer: pointer,
            inside: canvas,
            size: pill
        )
        expectSafe(result, pointer: pointer)
    }

    private func expectSafe(
        _ result: PointerCompanionLayoutResult,
        pointer: GlobalPoint
    ) {
        let protected = PointerCompanionLayout.protectedCursorRect(at: pointer)
        #expect(!intersects(result.frame, protected))
        #expect(result.frame.minX >= canvas.minX)
        #expect(result.frame.maxX <= canvas.maxX)
        #expect(result.frame.minY >= canvas.minY)
        #expect(result.frame.maxY <= canvas.maxY)
    }

    private func intersects(_ lhs: GlobalRect, _ rhs: GlobalRect) -> Bool {
        lhs.minX < rhs.maxX && lhs.maxX > rhs.minX &&
            lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
    }
}
