import PointerAgentContracts
@testable import PointerAgentHost
import Testing

@Suite("Human prompt activation")
struct AgentHumanPromptActivationTests {
    private let web = AgentProviderSessionIdentity(
        provider: .codex,
        nativeSessionID: "web"
    )
    private let other = AgentProviderSessionIdentity(
        provider: .codex,
        nativeSessionID: "other"
    )

    @Test("Startup selects the newest exact prompt and unchanged scans stay quiet")
    func startupBaseline() {
        var tracker = AgentHumanPromptActivationTracker()
        let webPrompt = candidate(web, offset: 10, timestamp: 100)
        let otherPrompt = candidate(other, offset: 20, timestamp: 200)
        let candidates = [webPrompt, otherPrompt]

        let winner = tracker.winner(among: candidates)
        #expect(winner == otherPrompt)
        tracker.commit(
            candidates,
            winner: winner,
            selectionSucceeded: true,
            discoveryObservedAtUnixNs: 250
        )
        #expect(tracker.winner(among: candidates) == nil)
    }

    @Test("A cursor change wins even when its wall clock is older")
    func cursorChangeBeatsForeignClock() {
        var tracker = AgentHumanPromptActivationTracker()
        let initial = [
            candidate(web, offset: 10, timestamp: 100),
            candidate(other, offset: 20, timestamp: 200),
        ]
        let initialWinner = tracker.winner(among: initial)
        tracker.commit(
            initial,
            winner: initialWinner,
            selectionSucceeded: true,
            discoveryObservedAtUnixNs: 250
        )

        let webChanged = candidate(web, offset: 30, timestamp: 150)
        let winner = tracker.winner(among: [webChanged, initial[1]])
        #expect(winner == webChanged)
    }

    @Test("A historical first-seen session is seeded without stealing attention")
    func historicalNewSessionDoesNotSteal() {
        var tracker = AgentHumanPromptActivationTracker()
        let baseline = candidate(web, offset: 10, timestamp: 100)
        tracker.commit(
            [baseline],
            winner: baseline,
            selectionSucceeded: true,
            discoveryObservedAtUnixNs: 250
        )

        let historical = candidate(other, offset: 50, timestamp: 200)
        #expect(tracker.winner(among: [baseline, historical]) == nil)
        tracker.commit(
            [baseline, historical],
            winner: nil,
            selectionSucceeded: false,
            discoveryObservedAtUnixNs: 300
        )
        #expect(tracker.winner(among: [baseline, historical]) == nil)
    }

    @Test("A failed selection leaves the changed prompt eligible for retry")
    func failedSelectionRetries() {
        var tracker = AgentHumanPromptActivationTracker()
        let baseline = candidate(web, offset: 10, timestamp: 100)
        tracker.commit(
            [baseline],
            winner: baseline,
            selectionSucceeded: true,
            discoveryObservedAtUnixNs: 150
        )
        let changed = candidate(web, offset: 20, timestamp: 200)
        let winner = tracker.winner(among: [changed])
        tracker.commit(
            [changed],
            winner: winner,
            selectionSucceeded: false,
            discoveryObservedAtUnixNs: 250
        )

        #expect(tracker.winner(among: [changed]) == changed)
    }

    @Test("Transcript previews are bounded by UTF-8 bytes before ingestion")
    func previewsAreProducerBounded() throws {
        let value = String(repeating: "a", count: 4_094) + "😀tail"
        let bounded = try #require(boundedHostUTF8(value, maximumBytes: 4_096))

        #expect(bounded.utf8.count == 4_094)
        #expect(String(decoding: bounded.utf8, as: UTF8.self) == bounded)
        #expect(boundedHostUTF8("short", maximumBytes: 4_096) == "short")
    }

    private func candidate(
        _ identity: AgentProviderSessionIdentity,
        offset: UInt64,
        timestamp: UInt64
    ) -> AgentHumanPromptActivationCandidate {
        AgentHumanPromptActivationCandidate(
            identity: identity,
            cursor: AgentHumanPromptCursor(
                device: 1,
                inode: identity == web ? 10 : 20,
                sourceOffset: offset
            ),
            timestampUnixNs: timestamp
        )
    }
}
