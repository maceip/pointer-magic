import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case cursor
}

/// PID reuse is normal. Every process reference therefore includes the kernel-reported
/// start time and must never be compared by PID alone.
public struct AgentProcessKey: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeUnixNs: UInt64

    public init(pid: Int32, startTimeUnixNs: UInt64) {
        self.pid = pid
        self.startTimeUnixNs = startTimeUnixNs
    }
}

public enum AgentProcessRole: String, Codable, Hashable, Sendable {
    /// The process has an agent command shape and a controlling terminal. This is an
    /// observation, not proof that the process owns the selected terminal tab.
    case interactiveCandidate
    /// A known background child such as an app server, MCP server, or sandbox helper.
    case helper
    /// The provider is recognizable but the process cannot be classified safely.
    case ambiguous
}

public struct AgentProcessSnapshot: Codable, Hashable, Sendable {
    public let key: AgentProcessKey
    public let provider: AgentProvider
    public let role: AgentProcessRole
    public let parentPID: Int32
    public let processGroupID: Int32
    public let terminalProcessGroupID: Int32
    public let kernelStatus: UInt32
    public let controllingTerminalDevice: UInt64
    public let controllingTTY: String?
    public let cwd: String?
    public let executablePath: String
    /// Bounded argv only. Environment variables are deliberately never collected.
    public let arguments: [String]
    /// Canonical transcript paths that the process had open during this census.
    public let openTranscriptPaths: [String]
    /// Exact provider-owned files/directories whose changes can wake transcript-only
    /// refresh. These remain separate from identity-bearing canonical stores.
    public let transcriptWakePaths: [String]
    public let isForegroundTerminalProcess: Bool
    public let argumentsTruncated: Bool
    public let openFilesTruncated: Bool
    public let observedAtUnixNs: UInt64

    public init(
        key: AgentProcessKey,
        provider: AgentProvider,
        role: AgentProcessRole,
        parentPID: Int32,
        processGroupID: Int32,
        terminalProcessGroupID: Int32,
        kernelStatus: UInt32,
        controllingTerminalDevice: UInt64,
        controllingTTY: String?,
        cwd: String?,
        executablePath: String,
        arguments: [String],
        openTranscriptPaths: [String],
        transcriptWakePaths: [String] = [],
        isForegroundTerminalProcess: Bool,
        argumentsTruncated: Bool,
        openFilesTruncated: Bool,
        observedAtUnixNs: UInt64
    ) {
        self.key = key
        self.provider = provider
        self.role = role
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.terminalProcessGroupID = terminalProcessGroupID
        self.kernelStatus = kernelStatus
        self.controllingTerminalDevice = controllingTerminalDevice
        self.controllingTTY = controllingTTY
        self.cwd = cwd
        self.executablePath = executablePath
        self.arguments = arguments
        self.openTranscriptPaths = openTranscriptPaths
        self.transcriptWakePaths = transcriptWakePaths
        self.isForegroundTerminalProcess = isForegroundTerminalProcess
        self.argumentsTruncated = argumentsTruncated
        self.openFilesTruncated = openFilesTruncated
        self.observedAtUnixNs = observedAtUnixNs
    }
}

public struct AgentTranscriptFileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modificationTimeUnixNs: UInt64

    public init(
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modificationTimeUnixNs: UInt64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationTimeUnixNs = modificationTimeUnixNs
    }
}

public enum AgentTranscriptRole: String, Codable, Hashable, Sendable {
    case root
    case internalSubagent
    case unknown
}

public enum AgentTranscriptEventKind: String, Codable, Hashable, Sendable {
    case sessionMetadata
    case userPrompt
    case assistantText
    case turnStarted
    case turnCompleted
    case turnAborted
}

/// Conservative activity inferred from a provider's persisted session store.
///
/// Cursor does not persist the TUI's exact `isGenerating` bit. An empty pending-tool
/// list therefore cannot prove that a live process is idle: the model may be working
/// between checkpoints. `quiescentUnknown` means only that the store has remained
/// unchanged beyond the bounded recent-activity window.
public enum AgentTranscriptActivityState: String, Codable, Hashable, Sendable {
    case working
    case activeRecently
    case quiescentUnknown
}

/// A structured provider-local image reference. Discovery preserves this separately
/// from message text so a literal string such as `[Image 1]` is never mistaken for
/// an attachment.
public struct AgentTranscriptImageAttachment: Codable, Hashable, Sendable {
    public let identifier: String
    public let localFilePath: String

    public init(identifier: String, localFilePath: String) {
        self.identifier = identifier
        self.localFilePath = localFilePath
    }
}

public struct AgentTranscriptEvent: Codable, Hashable, Sendable {
    public let kind: AgentTranscriptEventKind
    public let timestampUnixNs: UInt64?
    public let text: String?
    public let imageAttachments: [AgentTranscriptImageAttachment]
    /// Provider-local stable event cursor. This is a JSONL byte offset for Codex and
    /// Claude, and the immutable message-blob rowid for one Cursor store inode.
    public let sourceOffset: UInt64

    public init(
        kind: AgentTranscriptEventKind,
        timestampUnixNs: UInt64?,
        text: String?,
        imageAttachments: [AgentTranscriptImageAttachment] = [],
        sourceOffset: UInt64
    ) {
        self.kind = kind
        self.timestampUnixNs = timestampUnixNs
        self.text = text
        self.imageAttachments = imageAttachments
        self.sourceOffset = sourceOffset
    }
}

/// Provider identity remains provider-owned. It is never replaced with a hash of cwd,
/// because multiple simultaneous sessions may legitimately share one worktree.
public struct AgentTranscriptSnapshot: Codable, Hashable, Sendable {
    public let provider: AgentProvider
    public let providerSessionID: String
    public let role: AgentTranscriptRole
    public let path: String
    public let fileIdentity: AgentTranscriptFileIdentity
    public let cwd: String?
    public let latestUserPrompt: AgentTranscriptEvent?
    public let latestAssistantText: AgentTranscriptEvent?
    public let recentEvents: [AgentTranscriptEvent]
    public let nextReadOffset: UInt64
    public let replayWasTruncated: Bool
    public let activityState: AgentTranscriptActivityState?
    public let observedAtUnixNs: UInt64

    public init(
        provider: AgentProvider,
        providerSessionID: String,
        role: AgentTranscriptRole,
        path: String,
        fileIdentity: AgentTranscriptFileIdentity,
        cwd: String?,
        latestUserPrompt: AgentTranscriptEvent?,
        latestAssistantText: AgentTranscriptEvent?,
        recentEvents: [AgentTranscriptEvent],
        nextReadOffset: UInt64,
        replayWasTruncated: Bool,
        activityState: AgentTranscriptActivityState? = nil,
        observedAtUnixNs: UInt64
    ) {
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.role = role
        self.path = path
        self.fileIdentity = fileIdentity
        self.cwd = cwd
        self.latestUserPrompt = latestUserPrompt
        self.latestAssistantText = latestAssistantText
        self.recentEvents = recentEvents
        self.nextReadOffset = nextReadOffset
        self.replayWasTruncated = replayWasTruncated
        self.activityState = activityState
        self.observedAtUnixNs = observedAtUnixNs
    }
}

public enum AgentSessionCorrelationEvidence: String, Codable, Hashable, Sendable {
    /// The process had the exact canonical transcript file open.
    case openTranscriptFile
    /// A provider session ID was present in argv (`resume`, `--resume`, or
    /// `--session-id`).
    case explicitSessionArgument
    /// Same provider and canonical cwd with plausible timing. This is never sufficient
    /// for automatic routing when more than one candidate exists.
    case workspaceAndTimeCandidate
}

public struct AgentSessionCorrelation: Codable, Hashable, Sendable {
    public let process: AgentProcessKey
    public let transcriptPath: String
    public let providerSessionID: String
    public let evidence: AgentSessionCorrelationEvidence
    public let confidence: Double

    public init(
        process: AgentProcessKey,
        transcriptPath: String,
        providerSessionID: String,
        evidence: AgentSessionCorrelationEvidence,
        confidence: Double
    ) {
        self.process = process
        self.transcriptPath = transcriptPath
        self.providerSessionID = providerSessionID
        self.evidence = evidence
        self.confidence = min(max(confidence, 0), 1)
    }
}

public struct DiscoveredAgentSession: Codable, Hashable, Sendable {
    public let provider: AgentProvider
    public let providerSessionID: String?
    public let process: AgentProcessKey
    public let transcriptPath: String?
    public let cwd: String?
    public let correlation: AgentSessionCorrelation?
    /// True only for a unique strong correlation. A weak cwd/time candidate never
    /// becomes a route merely because it is the newest row.
    public let isUniquelyAddressed: Bool

    public init(
        provider: AgentProvider,
        providerSessionID: String?,
        process: AgentProcessKey,
        transcriptPath: String?,
        cwd: String?,
        correlation: AgentSessionCorrelation?,
        isUniquelyAddressed: Bool
    ) {
        self.provider = provider
        self.providerSessionID = providerSessionID
        self.process = process
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.correlation = correlation
        self.isUniquelyAddressed = isUniquelyAddressed
    }
}

public enum AgentDiscoveryGapKind: String, Codable, Hashable, Sendable {
    case processListTruncated
    case candidateProcessLimitReached
    case processArgumentsTruncated
    case processOpenFilesTruncated
    case transcriptDirectoryLimitReached
    case transcriptFileLimitReached
    case transcriptReadLimitReached
    case transcriptRecordTooLarge
    case transcriptUnavailable
}

public struct AgentDiscoveryGap: Codable, Hashable, Sendable {
    public let kind: AgentDiscoveryGapKind
    public let subject: String?

    public init(kind: AgentDiscoveryGapKind, subject: String? = nil) {
        self.kind = kind
        self.subject = subject
    }
}

public struct MacAgentDiscoverySnapshot: Codable, Hashable, Sendable {
    public let revision: UInt64
    public let observedAtUnixNs: UInt64
    public let processes: [AgentProcessSnapshot]
    public let transcripts: [AgentTranscriptSnapshot]
    public let sessions: [DiscoveredAgentSession]
    public let gaps: [AgentDiscoveryGap]

    public init(
        revision: UInt64,
        observedAtUnixNs: UInt64,
        processes: [AgentProcessSnapshot],
        transcripts: [AgentTranscriptSnapshot],
        sessions: [DiscoveredAgentSession],
        gaps: [AgentDiscoveryGap]
    ) {
        self.revision = revision
        self.observedAtUnixNs = observedAtUnixNs
        self.processes = processes
        self.transcripts = transcripts
        self.sessions = sessions
        self.gaps = gaps
    }

    public static let empty = MacAgentDiscoverySnapshot(
        revision: 0,
        observedAtUnixNs: 0,
        processes: [],
        transcripts: [],
        sessions: [],
        gaps: []
    )
}

@inline(__always)
func agentUnixTimeNs() -> UInt64 {
    let interval = Date().timeIntervalSince1970
    let nanoseconds = interval * 1_000_000_000
    guard nanoseconds.isFinite,
          nanoseconds > 0,
          nanoseconds < Double(UInt64.max)
    else { return 0 }
    return UInt64(nanoseconds)
}
