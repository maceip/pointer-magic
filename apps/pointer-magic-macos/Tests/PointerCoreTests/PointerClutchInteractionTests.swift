import Foundation
import PointerCore
import Testing

@Suite("Pointer clutch interaction")
struct PointerClutchInteractionTests {
    private let lease = PointerClutchLease(generation: 42, expiresAtNs: 1_000)

    @Test("Following begins with a generation-bound expiry")
    func beginsFollowing() {
        let state = PointerClutchReducer.reduce(
            state: .idle,
            event: .beginFollowing(lease: lease, nowNs: 100)
        )

        #expect(state == .following(lease))
    }

    @Test("Option down starts pinning")
    func optionDownStartsPinning() {
        let state = PointerClutchReducer.reduce(
            state: .following(lease),
            event: .optionDown(nowNs: 200)
        )

        #expect(state == .pinning(lease))
    }

    @Test("Entering the panel while pinning latches it")
    func pointerEntryLatches() {
        let state = PointerClutchReducer.reduce(
            state: .pinning(lease),
            event: .pointerEnteredPanel(nowNs: 300)
        )

        #expect(state == .latched(lease))
    }

    @Test("Option up before panel entry resumes following")
    func earlyOptionUpResumesFollowing() {
        let state = PointerClutchReducer.reduce(
            state: .pinning(lease),
            event: .optionUp(nowNs: 300)
        )

        #expect(state == .following(lease))
    }

    @Test("Option up after panel entry remains latched")
    func latchedOptionUpStaysLatched() {
        let state = PointerClutchReducer.reduce(
            state: .latched(lease),
            event: .optionUp(nowNs: 300)
        )

        #expect(state == .latched(lease))
    }

    @Test("The panel can explicitly resume following")
    func panelResumesFollowing() {
        let state = PointerClutchReducer.reduce(
            state: .latched(lease),
            event: .resumeFollowingFromPanel(nowNs: 400)
        )

        #expect(state == .following(lease))
    }

    @Test("Escape clears every active state", arguments: [
        PointerClutchState.following(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
        PointerClutchState.pinning(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
        PointerClutchState.latched(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
    ])
    func escapeClears(state: PointerClutchState) {
        #expect(PointerClutchReducer.reduce(state: state, event: .escape) == .idle)
    }

    @Test("Expiry clears every active state", arguments: [
        PointerClutchState.following(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
        PointerClutchState.pinning(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
        PointerClutchState.latched(PointerClutchLease(generation: 42, expiresAtNs: 1_000)),
    ])
    func expiryClears(state: PointerClutchState) {
        let next = PointerClutchReducer.reduce(
            state: state,
            event: .expiry(nowNs: 1_000)
        )

        #expect(next == .idle)
    }

    @Test("Expiry events before the deadline do not clear state")
    func earlyExpiryDoesNothing() {
        let state = PointerClutchState.latched(lease)
        let next = PointerClutchReducer.reduce(
            state: state,
            event: .expiry(nowNs: 999)
        )

        #expect(next == state)
    }

    @Test("Already-expired following requests remain idle")
    func expiredBeginStaysIdle() {
        let state = PointerClutchReducer.reduce(
            state: .idle,
            event: .beginFollowing(lease: lease, nowNs: 1_000)
        )

        #expect(state == .idle)
    }

    @Test("A new following lease replaces an expired active lease")
    func newLeaseReplacesExpiredState() {
        let expiredLease = PointerClutchLease(generation: 41, expiresAtNs: 50)
        let nextLease = PointerClutchLease(generation: 42, expiresAtNs: 1_000)
        let state = PointerClutchReducer.reduce(
            state: .latched(expiredLease),
            event: .beginFollowing(lease: nextLease, nowNs: 100)
        )

        #expect(state == .following(nextLease))
    }

    @Test("Clutch state survives a Codable round trip")
    func codableRoundTrip() throws {
        let state = PointerClutchState.latched(lease)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PointerClutchState.self, from: data)

        #expect(decoded == state)
    }
}
