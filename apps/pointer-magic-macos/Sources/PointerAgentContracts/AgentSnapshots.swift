import Foundation

// MARK: - Human attention selection

/// Explicit human choice, separate from an agent's inferred attention demand.
public enum AgentHumanAttentionTarget: Codable, Hashable, Sendable {
    case none
    case session(AgentProviderSessionIdentity)
}

public struct AgentHumanAttentionSelection: Codable, Hashable, Sendable {
    public let target: AgentHumanAttentionTarget
    public let selectedAtReceiverMonotonicNs: UInt64
    public let revision: AgentMemoryRevision

    public init(
        target: AgentHumanAttentionTarget,
        selectedAtReceiverMonotonicNs: UInt64,
        revision: AgentMemoryRevision
    ) {
        self.target = target
        self.selectedAtReceiverMonotonicNs = selectedAtReceiverMonotonicNs
        self.revision = revision
    }
}

public enum AgentAttentionSelectionUnavailableReason: String, Codable, Hashable, Sendable {
    case sessionNotFound
    case identityAmbiguous
    case sessionNotLive
}

public enum AgentAttentionSelectionResult: Codable, Hashable, Sendable {
    case selected(AgentHumanAttentionSelection)
    case unavailable(AgentAttentionSelectionUnavailableReason)
}

// MARK: - Immutable snapshots

public struct AgentProcessSnapshot: Codable, Hashable, Sendable {
    public let process: AgentProcessInstance
    public let liveness: AgentLiveness
    public let livenessEvidence: AgentEvidenceSet
    public let sourceRevision: AgentSourceRevision

    public init(
        process: AgentProcessInstance,
        liveness: AgentLiveness,
        livenessEvidence: AgentEvidenceSet,
        sourceRevision: AgentSourceRevision
    ) {
        self.process = process
        self.liveness = liveness
        self.livenessEvidence = livenessEvidence
        self.sourceRevision = sourceRevision
    }
}

public struct AgentSessionSnapshot: Codable, Hashable, Sendable {
    public let identity: AgentProviderSessionIdentity
    public let displayLabel: String?
    public let canonicalWorkingDirectory: String?
    public let canonicalWorktreeRoot: String?
    public let liveness: AgentLiveness
    public let execution: AgentExecutionState
    public let attentionDemand: AgentAttentionDemand
    public let boundedUserPrompt: String?
    public let boundedAssistantPreview: String?
    public let boundedUserImageAttachments: [AgentImageAttachment]
    public let boundedAssistantImageAttachments: [AgentImageAttachment]
    public let processes: [AgentProcessSnapshot]
    public let identityEvidence: AgentEvidenceSet
    public let livenessEvidence: AgentEvidenceSet
    public let executionEvidence: AgentEvidenceSet
    public let attentionEvidence: AgentEvidenceSet
    public let sourceRevision: AgentSourceRevision
    public let memoryRevision: AgentMemoryRevision

    public init(
        identity: AgentProviderSessionIdentity,
        displayLabel: String?,
        canonicalWorkingDirectory: String?,
        canonicalWorktreeRoot: String?,
        liveness: AgentLiveness,
        execution: AgentExecutionState,
        attentionDemand: AgentAttentionDemand,
        boundedUserPrompt: String?,
        boundedAssistantPreview: String?,
        boundedUserImageAttachments: [AgentImageAttachment] = [],
        boundedAssistantImageAttachments: [AgentImageAttachment] = [],
        processes: [AgentProcessSnapshot],
        identityEvidence: AgentEvidenceSet,
        livenessEvidence: AgentEvidenceSet,
        executionEvidence: AgentEvidenceSet,
        attentionEvidence: AgentEvidenceSet,
        sourceRevision: AgentSourceRevision,
        memoryRevision: AgentMemoryRevision
    ) {
        self.identity = identity
        self.displayLabel = displayLabel
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
        self.canonicalWorktreeRoot = canonicalWorktreeRoot
        self.liveness = liveness
        self.execution = execution
        self.attentionDemand = attentionDemand
        self.boundedUserPrompt = boundedUserPrompt
        self.boundedAssistantPreview = boundedAssistantPreview
        self.boundedUserImageAttachments = boundedUserImageAttachments
        self.boundedAssistantImageAttachments = boundedAssistantImageAttachments
        self.processes = processes
        self.identityEvidence = identityEvidence
        self.livenessEvidence = livenessEvidence
        self.executionEvidence = executionEvidence
        self.attentionEvidence = attentionEvidence
        self.sourceRevision = sourceRevision
        self.memoryRevision = memoryRevision
    }
}

public enum AgentIdentityAmbiguityReason: String, Codable, Hashable, Sendable {
    case multipleCandidateSessions
    case conflictingProcessBinding
    case conflictingSessionWorktree
    case insufficientEvidence
}

/// An ambiguity is visible for diagnostics but never appears as a resolved session.
public struct AgentIdentityAmbiguitySnapshot: Codable, Hashable, Sendable {
    public let process: AgentProcessInstanceIdentity?
    public let candidateSessions: [AgentProviderSessionIdentity]
    public let reason: AgentIdentityAmbiguityReason
    public let evidence: AgentEvidenceSet
    public let sourceRevision: AgentSourceRevision

    public init(
        process: AgentProcessInstanceIdentity?,
        candidateSessions: [AgentProviderSessionIdentity],
        reason: AgentIdentityAmbiguityReason,
        evidence: AgentEvidenceSet,
        sourceRevision: AgentSourceRevision
    ) {
        self.process = process
        self.candidateSessions = candidateSessions
        self.reason = reason
        self.evidence = evidence
        self.sourceRevision = sourceRevision
    }
}

/// Immutable, actor-independent view. Cache readers can retain this value; it
/// contains no mutable process handle and performs no I/O when queried.
public struct AgentShelfSnapshot: Codable, Hashable, Sendable {
    public let revision: AgentMemoryRevision
    public let generatedAtReceiverMonotonicNs: UInt64
    public let sessions: [AgentSessionSnapshot]
    public let ambiguities: [AgentIdentityAmbiguitySnapshot]
    public let attentionSelection: AgentHumanAttentionSelection
    public let didDropAmbiguityDiagnostics: Bool

    public init(
        revision: AgentMemoryRevision,
        generatedAtReceiverMonotonicNs: UInt64,
        sessions: [AgentSessionSnapshot],
        ambiguities: [AgentIdentityAmbiguitySnapshot],
        attentionSelection: AgentHumanAttentionSelection,
        didDropAmbiguityDiagnostics: Bool
    ) {
        self.revision = revision
        self.generatedAtReceiverMonotonicNs = generatedAtReceiverMonotonicNs
        self.sessions = sessions
        self.ambiguities = ambiguities
        self.attentionSelection = attentionSelection
        self.didDropAmbiguityDiagnostics = didDropAmbiguityDiagnostics
    }

    public var liveSessions: [AgentSessionSnapshot] {
        sessions.filter { $0.liveness == .live }
    }

    public static let empty = AgentShelfSnapshot(
        revision: AgentMemoryRevision(rawValue: 0),
        generatedAtReceiverMonotonicNs: 0,
        sessions: [],
        ambiguities: [],
        attentionSelection: AgentHumanAttentionSelection(
            target: .none,
            selectedAtReceiverMonotonicNs: 0,
            revision: AgentMemoryRevision(rawValue: 0)
        ),
        didDropAmbiguityDiagnostics: false
    )
}
