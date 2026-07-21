import Foundation

enum AgentSessionCorrelator {
    static func correlate(
        processes: [AgentProcessSnapshot],
        transcripts: [AgentTranscriptSnapshot]
    ) -> [DiscoveredAgentSession] {
        let roots = transcripts.filter { $0.role == .root }
        var output: [DiscoveredAgentSession] = []

        for process in processes where process.role != .helper {
            let providerRoots = roots.filter { $0.provider == process.provider }
            let open = Set(process.openTranscriptPaths)
            let openMatches = providerRoots.filter { open.contains($0.path) }
            let explicitIDs = explicitSessionIDs(in: process.arguments)
            let explicitMatches = providerRoots.filter {
                explicitIDs.contains($0.providerSessionID.lowercased())
            }
            let strongMatches = uniqueTranscripts(openMatches + explicitMatches)

            if !strongMatches.isEmpty {
                // Any conflict between exact FD and argv evidence, or more than one
                // open root transcript, fails closed. No newest-session tie breaker.
                let uniquelyAddressed = strongMatches.count == 1 && openMatches.count <= 1
                for transcript in strongMatches {
                    let evidence: AgentSessionCorrelationEvidence = open.contains(transcript.path)
                        ? .openTranscriptFile
                        : .explicitSessionArgument
                    let correlation = AgentSessionCorrelation(
                        process: process.key,
                        transcriptPath: transcript.path,
                        providerSessionID: transcript.providerSessionID,
                        evidence: evidence,
                        confidence: evidence == .openTranscriptFile ? 0.995 : 0.98
                    )
                    output.append(DiscoveredAgentSession(
                        provider: process.provider,
                        providerSessionID: transcript.providerSessionID,
                        process: process.key,
                        transcriptPath: transcript.path,
                        cwd: transcript.cwd ?? process.cwd,
                        correlation: correlation,
                        isUniquelyAddressed: uniquelyAddressed
                    ))
                }
                continue
            }

            let workspaceMatches = providerRoots.filter { transcript in
                guard canonicalEqual(process.cwd, transcript.cwd) else { return false }
                // The transcript may slightly predate process start when a provider is
                // resuming it. A five-minute allowance is only candidate evidence.
                let allowance: UInt64 = 5 * 60 * 1_000_000_000
                return transcript.fileIdentity.modificationTimeUnixNs + allowance >=
                    process.key.startTimeUnixNs
            }
            if workspaceMatches.isEmpty {
                output.append(DiscoveredAgentSession(
                    provider: process.provider,
                    providerSessionID: nil,
                    process: process.key,
                    transcriptPath: nil,
                    cwd: process.cwd,
                    correlation: nil,
                    isUniquelyAddressed: false
                ))
            } else {
                for transcript in workspaceMatches {
                    let correlation = AgentSessionCorrelation(
                        process: process.key,
                        transcriptPath: transcript.path,
                        providerSessionID: transcript.providerSessionID,
                        evidence: .workspaceAndTimeCandidate,
                        confidence: 0.4
                    )
                    output.append(DiscoveredAgentSession(
                        provider: process.provider,
                        providerSessionID: transcript.providerSessionID,
                        process: process.key,
                        transcriptPath: transcript.path,
                        cwd: transcript.cwd ?? process.cwd,
                        correlation: correlation,
                        isUniquelyAddressed: false
                    ))
                }
            }
        }

        return output.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.isUniquelyAddressed != $1.isUniquelyAddressed {
                return $0.isUniquelyAddressed && !$1.isUniquelyAddressed
            }
            if $0.providerSessionID != $1.providerSessionID {
                return ($0.providerSessionID ?? "") < ($1.providerSessionID ?? "")
            }
            return $0.process.pid < $1.process.pid
        }
    }

    private static func uniqueTranscripts(
        _ values: [AgentTranscriptSnapshot]
    ) -> [AgentTranscriptSnapshot] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.path).inserted }
    }

    private static func explicitSessionIDs(in arguments: [String]) -> Set<String> {
        var result: Set<String> = []
        let flags: Set<String> = ["--session-id", "--resume", "-r", "resume"]
        for (index, argument) in arguments.enumerated() {
            let lower = argument.lowercased()
            for prefix in ["--session-id=", "--resume="] where lower.hasPrefix(prefix) {
                let value = String(lower.dropFirst(prefix.count))
                if UUID(uuidString: value) != nil { result.insert(value) }
            }
            if flags.contains(lower), arguments.indices.contains(index + 1) {
                let value = arguments[index + 1].lowercased()
                if UUID(uuidString: value) != nil { result.insert(value) }
            }
        }
        return result
    }

    private static func canonicalEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        let left = URL(fileURLWithPath: lhs)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let right = URL(fileURLWithPath: rhs)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return left == right
    }
}
