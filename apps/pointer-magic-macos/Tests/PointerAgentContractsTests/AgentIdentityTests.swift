import PointerAgentContracts
import Testing

@Suite("Agent identity contracts")
struct AgentIdentityTests {
    @Test("Provider identity, not workspace, distinguishes sessions")
    func providerIdentityDistinguishesSessions() {
        let first = AgentProviderSessionIdentity(
            provider: .codex,
            nativeSessionID: "11111111-1111-1111-1111-111111111111"
        )
        let second = AgentProviderSessionIdentity(
            provider: .codex,
            nativeSessionID: "22222222-2222-2222-2222-222222222222"
        )

        #expect(first != second)
    }

    @Test("Liveness, execution, and attention demand remain independent")
    func stateDimensionsRemainIndependent() {
        let liveness: AgentLiveness = .live
        let execution: AgentExecutionState = .completed
        let demand: AgentAttentionDemand = .verification

        #expect(liveness == .live)
        #expect(execution == .completed)
        #expect(demand == .verification)
    }
}
