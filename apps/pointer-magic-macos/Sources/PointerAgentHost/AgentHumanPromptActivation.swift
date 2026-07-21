import PointerAgentContracts

/// Position of one human prompt inside one canonical transcript incarnation.
/// Offsets are never compared across transcript files.
struct AgentHumanPromptCursor: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let sourceOffset: UInt64
}

struct AgentHumanPromptActivationCandidate: Hashable, Sendable {
    let identity: AgentProviderSessionIdentity
    let cursor: AgentHumanPromptCursor
    let timestampUnixNs: UInt64

    fileprivate var orderingKey: (UInt64, UInt64, String) {
        (
            timestampUnixNs,
            cursor.sourceOffset,
            identity.provider.stableIdentifier + ":" + identity.nativeSessionID
        )
    }
}

/// Tracks human input independently for every exact provider session. Global wall
/// clocks are used only to choose between multiple changed sessions observed in the
/// same discovery revision; they never suppress a cursor change in another session.
struct AgentHumanPromptActivationTracker: Sendable {
    private var cursorBySession: [
        AgentProviderSessionIdentity: AgentHumanPromptCursor
    ] = [:]
    private var didEstablishBaseline = false
    private var lastCommittedDiscoveryObservedAtUnixNs: UInt64 = 0

    func winner(
        among candidates: [AgentHumanPromptActivationCandidate]
    ) -> AgentHumanPromptActivationCandidate? {
        candidates
            .filter { candidate in
                if !didEstablishBaseline { return true }
                if let previous = cursorBySession[candidate.identity] {
                    return previous != candidate.cursor
                }
                // A newly correlatable process with an old transcript is not proof
                // of new attention. A prompt written after the prior census is.
                return candidate.timestampUnixNs > lastCommittedDiscoveryObservedAtUnixNs
            }
            .max { lhs, rhs in lhs.orderingKey < rhs.orderingKey }
    }

    mutating func commit(
        _ candidates: [AgentHumanPromptActivationCandidate],
        winner: AgentHumanPromptActivationCandidate?,
        selectionSucceeded: Bool,
        discoveryObservedAtUnixNs: UInt64
    ) {
        for candidate in candidates {
            // A temporarily unavailable winner remains changed and is retried on the
            // next committed discovery revision. Non-winning cursors are seeded.
            if candidate.identity == winner?.identity, !selectionSucceeded {
                continue
            }
            cursorBySession[candidate.identity] = candidate.cursor
        }
        didEstablishBaseline = true
        lastCommittedDiscoveryObservedAtUnixNs = discoveryObservedAtUnixNs
    }
}
