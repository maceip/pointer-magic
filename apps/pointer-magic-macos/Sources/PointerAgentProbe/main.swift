import Foundation
import PointerAgentContracts
import PointerAgentHost
import PointerMacAgentDiscovery

private struct ProbeOutput: Codable {
    let revision: UInt64
    let processCount: Int
    let transcriptCount: Int
    let exactSessionCount: Int
    let reducedSessionCount: Int
    let selectedSessionID: String?
    let selectedExecution: String?
    let selectedAttentionDemand: String?
    let lastIngestStatus: String?
    let lastIngestRejection: String?
    let gaps: [String]
    let sessions: [ProbeSession]
}

private struct ProbeSession: Codable {
    let provider: String
    let processID: Int32
    let sessionID: String
    let cwd: String?
    let transcriptPath: String?
    let latestPromptTimestampUnixNs: UInt64?
    let latestPromptOffset: UInt64?
    let latestPrompt: String?
    let latestAssistant: String?
}

@main
struct PointerAgentProbe {
    static func main() async throws {
        let host = AgentObservationHost()
        let reduced = await host.refreshNow()
        let snapshot = await host.discovery.snapshot()
        let transcripts = Dictionary(
            uniqueKeysWithValues: snapshot.transcripts.map { ($0.path, $0) }
        )
        let sessions = snapshot.sessions.compactMap { session -> ProbeSession? in
            guard session.isUniquelyAddressed, let sessionID = session.providerSessionID else {
                return nil
            }
            let transcript = session.transcriptPath.flatMap { transcripts[$0] }
            return ProbeSession(
                provider: session.provider.rawValue,
                processID: session.process.pid,
                sessionID: sessionID,
                cwd: session.cwd,
                transcriptPath: session.transcriptPath,
                latestPromptTimestampUnixNs: transcript?.latestUserPrompt?.timestampUnixNs,
                latestPromptOffset: transcript?.latestUserPrompt?.sourceOffset,
                latestPrompt: transcript?.latestUserPrompt?.text,
                latestAssistant: transcript?.latestAssistantText?.text
            )
        }
        let status = await host.status()
        let output = ProbeOutput(
            revision: snapshot.revision,
            processCount: snapshot.processes.count,
            transcriptCount: snapshot.transcripts.count,
            exactSessionCount: sessions.count,
            reducedSessionCount: reduced.sessions.count,
            selectedSessionID: selectedSessionID(reduced.attentionSelection.target),
            selectedExecution: selectedSession(reduced)?.execution.rawValue,
            selectedAttentionDemand: selectedSession(reduced)?.attentionDemand.rawValue,
            lastIngestStatus: status.lastIngestStatus?.rawValue,
            lastIngestRejection: status.lastIngestRejection.map { String(describing: $0) },
            gaps: snapshot.gaps.map { $0.kind.rawValue },
            sessions: sessions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func selectedSessionID(
        _ target: AgentHumanAttentionTarget
    ) -> String? {
        guard case let .session(identity) = target else { return nil }
        return identity.nativeSessionID
    }

    private static func selectedSession(
        _ snapshot: AgentShelfSnapshot
    ) -> AgentSessionSnapshot? {
        guard case let .session(identity) = snapshot.attentionSelection.target else {
            return nil
        }
        return snapshot.sessions.first { $0.identity == identity }
    }
}
