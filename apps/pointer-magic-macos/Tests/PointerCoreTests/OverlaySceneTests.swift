import PointerCore
import Testing

@Suite("Overlay scene contract")
struct OverlaySceneTests {
    @Test("A current, bounded scene validates")
    func validScene() throws {
        let scene = makeScene(generation: 8, now: 100)
        try scene.validate(currentGeneration: 8, nowNs: 100)
    }

    @Test("Stale scenes cannot overwrite current pointer state")
    func staleScene() {
        let scene = makeScene(generation: 7, now: 100)
        #expect(throws: OverlayValidationError.staleGeneration) {
            try scene.validate(currentGeneration: 8, nowNs: 100)
        }
    }

    @Test("Future scenes cannot skip the current generation")
    func futureScene() {
        let scene = makeScene(generation: 9, now: 100)
        #expect(throws: OverlayValidationError.staleGeneration) {
            try scene.validate(currentGeneration: 8, nowNs: 100)
        }
    }

    @Test("Scenes always expire")
    func expiredScene() {
        let scene = makeScene(generation: 8, now: 100)
        #expect(throws: OverlayValidationError.expired) {
            try scene.validate(currentGeneration: 8, nowNs: 1_000_000_101)
        }
    }

    @Test("The renderer contract is bounded")
    func boundedItems() {
        var scene = makeScene(generation: 8, now: 100)
        scene.items = (0..<9).map {
            HaloItem(
                id: "item-\($0)",
                symbol: "✦",
                label: "Item \($0)",
                angleRadians: Double($0),
                accent: .cyan
            )
        }
        #expect(throws: OverlayValidationError.tooManyItems) {
            try scene.validate(currentGeneration: 8, nowNs: 100)
        }
    }

    private func makeScene(generation: UInt64, now: UInt64) -> OverlayScene {
        OverlayScene(
            sourceID: "tests",
            generation: generation,
            createdAtNs: now,
            expiresAtNs: now + 1_000_000_000,
            anchor: GlobalPoint(x: 20, y: 20),
            items: []
        )
    }
}
