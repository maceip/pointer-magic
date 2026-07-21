import PointerCore
import Testing

@Suite("Pointer interaction modifier state")
struct PointerInteractionModifierTrackerTests {
    @Test("Initial held keys establish a baseline without arming interaction")
    func heldAtStartupDoesNotEmitPress() {
        var tracker = PointerInteractionModifierTracker(initialState: [.rightOption])

        #expect(tracker.update(to: [.rightOption]).isEmpty)
        #expect(tracker.update(to: []).first == .released(.rightOption))
        #expect(tracker.update(to: [.rightOption]).first == .pressed(.rightOption))
    }

    @Test("Right Option and Right Command produce independent deduplicated edges")
    func tracksBothRightModifiers() {
        var tracker = PointerInteractionModifierTracker(initialState: [])

        #expect(tracker.update(to: [.rightCommand]) == [.pressed(.rightCommand)])
        #expect(tracker.update(to: [.rightCommand]).isEmpty)
        #expect(tracker.update(to: [.rightOption, .rightCommand]) == [
            .pressed(.rightOption),
        ])
        #expect(tracker.update(to: [.rightOption]) == [.released(.rightCommand)])
    }

    @Test("A direct modifier handoff releases before it presses")
    func handoffOrdering() {
        var tracker = PointerInteractionModifierTracker(initialState: [.rightOption])

        #expect(tracker.update(to: [.rightCommand]) == [
            .released(.rightOption),
            .pressed(.rightCommand),
        ])
    }

    @Test("Discrete kinds preserve physical modifier identity and direction")
    func discreteKindRoundTrip() throws {
        for transition in [
            PointerInteractionModifierTransition.pressed(.rightOption),
            .released(.rightOption),
            .pressed(.rightCommand),
            .released(.rightCommand),
        ] {
            let kind = PointerDiscreteKind(transition)
            #expect(kind.interactionModifierTransition == transition)
        }
    }
}
