import Foundation
import PointerAgentContracts
import PointerAgentMemory
import Testing

@Suite("Agent memory")
struct AgentMemoryStoreTests {
    @Test("A uniquely bound live session can be selected")
    func exactLiveSelection() async throws {
        let store = AgentMemoryStore(receiverMonotonicNow: { 900 })
        let epoch = AgentObservationSourceEpoch(
            sourceID: AgentObservationSourceID(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            epochID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let identity = AgentProviderSessionIdentity(
            provider: .codex,
            nativeSessionID: "11111111-1111-1111-1111-111111111111"
        )
        let processIdentity = AgentProcessInstanceIdentity(
            hostBootID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            pid: 42,
            startedAtUnixNs: 100
        )
        let evidence = AgentEvidenceSet(
            confidence: .authoritative,
            items: [
                AgentEvidence(
                    kind: .openTranscriptFile,
                    observedAtSourceMonotonicNs: 500,
                    detailCode: "exact-open-file"
                ),
            ]
        )
        let events = [
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 1),
                payload: .session(AgentSessionObservation(
                    identity: identity,
                    canonicalWorkingDirectory: "/tmp/worktree",
                    execution: .working,
                    attentionDemand: .none,
                    boundedAssistantPreview: "Building the native shelf.",
                    evidence: evidence
                ))
            ),
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 2),
                payload: .process(AgentProcessObservation(
                    process: AgentProcessInstance(
                        identity: processIdentity,
                        executablePath: "/usr/local/bin/codex",
                        canonicalWorkingDirectory: "/tmp/worktree",
                        tty: "ttys001"
                    ),
                    liveness: .live,
                    evidence: evidence
                ))
            ),
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 3),
                payload: .processSessionBinding(AgentProcessSessionBindingObservation(
                    process: processIdentity,
                    candidateSessions: [identity],
                    evidence: evidence
                ))
            ),
        ]

        let receipt = await store.ingest(AgentObservationBatch(events: events))
        #expect(receipt.status == .accepted)
        let selection = await store.selectAttention(.session(identity))
        guard case .selected = selection else {
            Issue.record("Exact live session was not selectable")
            return
        }
        let snapshot = await store.shelfSnapshot()
        #expect(snapshot.liveSessions.map(\.identity) == [identity])
        #expect(snapshot.attentionSelection.target == .session(identity))
    }

    @Test("Ambiguous bindings never become resolved sessions")
    func ambiguousBindingFailsClosed() async {
        let store = AgentMemoryStore(receiverMonotonicNow: { 900 })
        let epoch = AgentObservationSourceEpoch(
            sourceID: AgentObservationSourceID(),
            epochID: UUID()
        )
        let processIdentity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 43,
            startedAtUnixNs: 101
        )
        let first = AgentProviderSessionIdentity(provider: .codex, nativeSessionID: "one")
        let second = AgentProviderSessionIdentity(provider: .codex, nativeSessionID: "two")
        let evidence = AgentEvidenceSet(
            confidence: .corroborated,
            items: [AgentEvidence(
                kind: .openTranscriptFile,
                observedAtSourceMonotonicNs: 500
            )]
        )
        let events = [
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 1),
                payload: .session(AgentSessionObservation(identity: first, evidence: evidence))
            ),
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 2),
                payload: .session(AgentSessionObservation(identity: second, evidence: evidence))
            ),
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 3),
                payload: .process(AgentProcessObservation(
                    process: AgentProcessInstance(identity: processIdentity),
                    liveness: .live,
                    evidence: evidence
                ))
            ),
            AgentObservationEnvelope(
                revision: AgentSourceRevision(sourceEpoch: epoch, sequence: 4),
                payload: .processSessionBinding(AgentProcessSessionBindingObservation(
                    process: processIdentity,
                    candidateSessions: [first, second],
                    evidence: evidence
                ))
            ),
        ]

        let receipt = await store.ingest(AgentObservationBatch(events: events))
        #expect(receipt.status == .acceptedWithAmbiguity)
        let snapshot = await store.shelfSnapshot()
        #expect(snapshot.liveSessions.isEmpty)
        #expect(snapshot.ambiguities.count == 1)
    }
}
