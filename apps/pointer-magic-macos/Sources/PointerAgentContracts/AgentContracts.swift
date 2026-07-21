import Foundation

// MARK: - Provider and process identity

/// The provider namespace is part of session identity. A provider-native ID is
/// never compared across providers, and a working directory is never an identity.
public enum AgentProvider: Codable, Hashable, Sendable {
    case codex
    case claudeCode
    case cursor
    case other(String)

    public var stableIdentifier: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude-code"
        case .cursor: "cursor"
        case let .other(identifier): "other:\(identifier)"
        }
    }
}

/// Exact identity issued by an agent provider. PID, TTY, label, repository, and
/// working directory are deliberately absent because none of them identifies a
/// provider session uniquely.
public struct AgentProviderSessionIdentity: Codable, Hashable, Sendable {
    public let provider: AgentProvider
    public let nativeSessionID: String

    public init(provider: AgentProvider, nativeSessionID: String) {
        self.provider = provider
        self.nativeSessionID = nativeSessionID
    }
}

/// One operating-system process incarnation. The host boot identity and process
/// start time prevent a recycled PID from aliasing an earlier process.
public struct AgentProcessInstanceIdentity: Codable, Hashable, Sendable {
    public let hostBootID: UUID
    public let pid: Int32
    public let startedAtUnixNs: UInt64

    public init(hostBootID: UUID, pid: Int32, startedAtUnixNs: UInt64) {
        self.hostBootID = hostBootID
        self.pid = pid
        self.startedAtUnixNs = startedAtUnixNs
    }
}

/// Immutable process facts. Paths must already be canonicalized by the platform
/// adapter; this transport-neutral layer never performs filesystem I/O.
public struct AgentProcessInstance: Codable, Hashable, Sendable {
    public let identity: AgentProcessInstanceIdentity
    public let parentPID: Int32?
    public let executablePath: String?
    public let canonicalWorkingDirectory: String?
    public let tty: String?

    public init(
        identity: AgentProcessInstanceIdentity,
        parentPID: Int32? = nil,
        executablePath: String? = nil,
        canonicalWorkingDirectory: String? = nil,
        tty: String? = nil
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
        self.tty = tty
    }
}

// MARK: - Independent state dimensions

/// Whether a correlated operating-system process is presently observed alive.
/// Liveness is process evidence; it must not be inferred from transcript silence.
public enum AgentLiveness: String, Codable, Hashable, Sendable {
    case unknown
    case live
    case notRunning
}

/// What the provider session is doing. This is intentionally independent from
/// both process liveness and whether it needs human attention.
public enum AgentExecutionState: String, Codable, Hashable, Sendable {
    case unknown
    case starting
    case working
    case waitingForTool
    case idle
    case completed
    case failed
}

/// A provider-observed reason that the session may need a person. `none` means
/// evidence says no demand; `unknown` means the observer cannot determine it.
public enum AgentAttentionDemand: String, Codable, Hashable, Sendable {
    case unknown
    case none
    case question
    case permission
    case confirmation
    case verification
    case failure
}

/// A provider-authored image reference attached to one transcript message.
///
/// `sourceLocalFilePath` is meaningful only on the observation source that emitted
/// it. Network projections may carry the descriptor for identity/provenance, but a
/// receiver must never try to open the path unless that source is the local host.
public struct AgentImageAttachment: Codable, Hashable, Sendable {
    public let identifier: String
    public let sourceLocalFilePath: String
    public let displayName: String?

    public init(
        identifier: String,
        sourceLocalFilePath: String,
        displayName: String? = nil
    ) {
        self.identifier = identifier
        self.sourceLocalFilePath = sourceLocalFilePath
        self.displayName = displayName
    }
}

// MARK: - Evidence and confidence

public enum AgentEvidenceKind: String, Codable, Hashable, Sendable {
    case providerTranscript
    case providerHook
    case processTable
    case processCommandLine
    case openTranscriptFile
    case terminalAssociation
    case persistedCheckpoint
    case explicitHumanSelection
}

/// Confidence is ordinal and describes the evidence set, not the session state.
/// Reducers may require a minimum level for identity joins without pretending a
/// weak heuristic is authoritative.
public enum AgentEvidenceConfidence: Int, Codable, Hashable, Sendable, Comparable {
    case weak = 0
    case corroborated = 1
    case authoritative = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One bounded, machine-readable provenance item. `detailCode` is a diagnostic
/// code, not a channel for transcript or command content.
public struct AgentEvidence: Codable, Hashable, Sendable {
    public let kind: AgentEvidenceKind
    public let observedAtSourceMonotonicNs: UInt64
    public let detailCode: String?

    public init(
        kind: AgentEvidenceKind,
        observedAtSourceMonotonicNs: UInt64,
        detailCode: String? = nil
    ) {
        self.kind = kind
        self.observedAtSourceMonotonicNs = observedAtSourceMonotonicNs
        self.detailCode = detailCode
    }
}

public struct AgentEvidenceSet: Codable, Hashable, Sendable {
    public let confidence: AgentEvidenceConfidence
    public let items: [AgentEvidence]

    public init(confidence: AgentEvidenceConfidence, items: [AgentEvidence]) {
        self.confidence = confidence
        self.items = items
    }
}

// MARK: - Revisions

public struct AgentObservationSourceID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Restart boundary for an observer. Sequence numbers are meaningful only inside
/// an epoch and an old epoch can never alias its replacement.
public struct AgentObservationSourceEpoch: Codable, Hashable, Sendable {
    public let sourceID: AgentObservationSourceID
    public let epochID: UUID

    public init(sourceID: AgentObservationSourceID, epochID: UUID = UUID()) {
        self.sourceID = sourceID
        self.epochID = epochID
    }
}

public struct AgentSourceRevision: Codable, Hashable, Sendable {
    public let sourceEpoch: AgentObservationSourceEpoch
    public let sequence: UInt64

    public init(sourceEpoch: AgentObservationSourceEpoch, sequence: UInt64) {
        self.sourceEpoch = sourceEpoch
        self.sequence = sequence
    }
}

/// Receiver-owned revision of one fully reduced immutable snapshot.
public struct AgentMemoryRevision: Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Observations

/// Provider-session facts. Process liveness is intentionally not accepted here.
public struct AgentSessionObservation: Codable, Hashable, Sendable {
    public let identity: AgentProviderSessionIdentity
    public let displayLabel: String?
    public let canonicalWorkingDirectory: String?
    public let canonicalWorktreeRoot: String?
    public let execution: AgentExecutionState
    public let attentionDemand: AgentAttentionDemand
    public let boundedUserPrompt: String?
    public let boundedAssistantPreview: String?
    public let boundedUserImageAttachments: [AgentImageAttachment]
    public let boundedAssistantImageAttachments: [AgentImageAttachment]
    public let evidence: AgentEvidenceSet

    public init(
        identity: AgentProviderSessionIdentity,
        displayLabel: String? = nil,
        canonicalWorkingDirectory: String? = nil,
        canonicalWorktreeRoot: String? = nil,
        execution: AgentExecutionState = .unknown,
        attentionDemand: AgentAttentionDemand = .unknown,
        boundedUserPrompt: String? = nil,
        boundedAssistantPreview: String? = nil,
        boundedUserImageAttachments: [AgentImageAttachment] = [],
        boundedAssistantImageAttachments: [AgentImageAttachment] = [],
        evidence: AgentEvidenceSet
    ) {
        self.identity = identity
        self.displayLabel = displayLabel
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
        self.canonicalWorktreeRoot = canonicalWorktreeRoot
        self.execution = execution
        self.attentionDemand = attentionDemand
        self.boundedUserPrompt = boundedUserPrompt
        self.boundedAssistantPreview = boundedAssistantPreview
        self.boundedUserImageAttachments = boundedUserImageAttachments
        self.boundedAssistantImageAttachments = boundedAssistantImageAttachments
        self.evidence = evidence
    }
}

/// Process-only observation. It cannot assert a provider session identity.
public struct AgentProcessObservation: Codable, Hashable, Sendable {
    public let process: AgentProcessInstance
    public let liveness: AgentLiveness
    public let evidence: AgentEvidenceSet

    public init(
        process: AgentProcessInstance,
        liveness: AgentLiveness,
        evidence: AgentEvidenceSet
    ) {
        self.process = process
        self.liveness = liveness
        self.evidence = evidence
    }
}

/// A correlation claim is explicit about every candidate. The reducer binds only
/// one corroborated candidate; zero, multiple, or conflicting candidates remain
/// unresolved and cannot silently become the first matching session.
public struct AgentProcessSessionBindingObservation: Codable, Hashable, Sendable {
    public let process: AgentProcessInstanceIdentity
    public let candidateSessions: [AgentProviderSessionIdentity]
    public let evidence: AgentEvidenceSet

    public init(
        process: AgentProcessInstanceIdentity,
        candidateSessions: [AgentProviderSessionIdentity],
        evidence: AgentEvidenceSet
    ) {
        self.process = process
        self.candidateSessions = candidateSessions
        self.evidence = evidence
    }
}

public enum AgentObservationPayload: Codable, Hashable, Sendable {
    case session(AgentSessionObservation)
    case process(AgentProcessObservation)
    case processSessionBinding(AgentProcessSessionBindingObservation)
}

public struct AgentObservationEnvelope: Codable, Hashable, Sendable {
    public let revision: AgentSourceRevision
    public let payload: AgentObservationPayload

    public init(revision: AgentSourceRevision, payload: AgentObservationPayload) {
        self.revision = revision
        self.payload = payload
    }
}

public struct AgentObservationBatch: Codable, Hashable, Sendable {
    public let events: [AgentObservationEnvelope]
    public init(events: [AgentObservationEnvelope]) { self.events = events }
}

// MARK: - Ingestion boundary

public enum AgentIngestStatus: String, Codable, Hashable, Sendable {
    case accepted
    case acceptedWithAmbiguity
    case replayed
    case rejected
}

public enum AgentIngestRejection: Error, Codable, Hashable, Sendable {
    case emptyBatch
    case batchLimitExceeded(maximum: Int, actual: Int)
    case sourceLimitExceeded(maximum: Int)
    case mixedSourceEpoch
    case invalidRevision
    case revisionGap(expected: UInt64, found: UInt64)
    case outOfOrder(previous: UInt64, found: UInt64)
    case revisionEquivocation(sequence: UInt64)
    case invalidIdentity(field: String)
    case invalidProcess(field: String)
    case invalidEvidence(field: String)
    case fieldLimitExceeded(field: String, maximum: Int, actual: Int)
    case insufficientIdentityEvidence
    case processUnavailable
    case capacityExceeded(resource: String, maximum: Int)
}

public struct AgentIngestReceipt: Codable, Hashable, Sendable {
    public let status: AgentIngestStatus
    public let memoryRevision: AgentMemoryRevision
    public let acceptedThrough: AgentSourceRevision?
    public let ambiguityCount: Int
    public let rejection: AgentIngestRejection?

    public init(
        status: AgentIngestStatus,
        memoryRevision: AgentMemoryRevision,
        acceptedThrough: AgentSourceRevision? = nil,
        ambiguityCount: Int = 0,
        rejection: AgentIngestRejection? = nil
    ) {
        self.status = status
        self.memoryRevision = memoryRevision
        self.acceptedThrough = acceptedThrough
        self.ambiguityCount = ambiguityCount
        self.rejection = rejection
    }
}

public protocol AgentObservationSink: Sendable {
    func ingest(_ batch: AgentObservationBatch) async -> AgentIngestReceipt
}
