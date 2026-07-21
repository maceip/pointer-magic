import Foundation
import PointerAgentContracts

public enum AgentMemoryConfigurationError: Error, Equatable, Sendable {
    case invalidLimit
}

/// Hard receiver-side bounds. Capacity exhaustion rejects new identity-bearing
/// state instead of evicting evidence and accidentally making an ambiguous join
/// appear unique.
public struct AgentMemoryLimits: Hashable, Sendable {
    public let maximumSessions: Int
    public let maximumProcesses: Int
    public let maximumSourceEpochs: Int
    public let maximumEventsPerBatch: Int
    public let maximumReplayEntriesPerSource: Int
    public let maximumEvidenceItems: Int
    public let maximumBindingCandidates: Int
    public let maximumAmbiguityDiagnostics: Int
    public let maximumIdentifierBytes: Int
    public let maximumPathBytes: Int
    public let maximumLabelBytes: Int
    public let maximumPreviewBytes: Int

    public init(
        maximumSessions: Int = 256,
        maximumProcesses: Int = 512,
        maximumSourceEpochs: Int = 64,
        maximumEventsPerBatch: Int = 256,
        maximumReplayEntriesPerSource: Int = 1_024,
        maximumEvidenceItems: Int = 32,
        maximumBindingCandidates: Int = 16,
        maximumAmbiguityDiagnostics: Int = 256,
        maximumIdentifierBytes: Int = 256,
        maximumPathBytes: Int = 4_096,
        maximumLabelBytes: Int = 512,
        maximumPreviewBytes: Int = 4_096
    ) throws {
        let values = [
            maximumSessions,
            maximumProcesses,
            maximumSourceEpochs,
            maximumEventsPerBatch,
            maximumReplayEntriesPerSource,
            maximumEvidenceItems,
            maximumBindingCandidates,
            maximumAmbiguityDiagnostics,
            maximumIdentifierBytes,
            maximumPathBytes,
            maximumLabelBytes,
            maximumPreviewBytes,
        ]
        guard values.allSatisfy({ $0 > 0 }) else {
            throw AgentMemoryConfigurationError.invalidLimit
        }
        self.maximumSessions = maximumSessions
        self.maximumProcesses = maximumProcesses
        self.maximumSourceEpochs = maximumSourceEpochs
        self.maximumEventsPerBatch = maximumEventsPerBatch
        self.maximumReplayEntriesPerSource = maximumReplayEntriesPerSource
        self.maximumEvidenceItems = maximumEvidenceItems
        self.maximumBindingCandidates = maximumBindingCandidates
        self.maximumAmbiguityDiagnostics = maximumAmbiguityDiagnostics
        self.maximumIdentifierBytes = maximumIdentifierBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumLabelBytes = maximumLabelBytes
        self.maximumPreviewBytes = maximumPreviewBytes
    }

    public static let `default` = try! AgentMemoryLimits()
}

private struct SessionRecord: Sendable {
    let identity: AgentProviderSessionIdentity
    var displayLabel: String?
    var canonicalWorkingDirectory: String?
    var canonicalWorktreeRoot: String?
    var execution: AgentExecutionState
    var attentionDemand: AgentAttentionDemand
    var boundedUserPrompt: String?
    var boundedAssistantPreview: String?
    var boundedUserImageAttachments: [AgentImageAttachment]
    var boundedAssistantImageAttachments: [AgentImageAttachment]
    var identityEvidence: AgentEvidenceSet
    var executionEvidence: AgentEvidenceSet
    var attentionEvidence: AgentEvidenceSet
    var sourceRevision: AgentSourceRevision
    var lastMutationOrdinal: UInt64
}

private struct ProcessRecord: Sendable {
    var process: AgentProcessInstance
    var liveness: AgentLiveness
    var evidence: AgentEvidenceSet
    var sourceRevision: AgentSourceRevision
    var lastMutationOrdinal: UInt64
}

private struct BindingRecord: Sendable {
    let session: AgentProviderSessionIdentity
    var evidence: AgentEvidenceSet
    var sourceRevision: AgentSourceRevision
}

private struct PendingBinding: Sendable {
    var candidates: [AgentProviderSessionIdentity]
    var evidence: AgentEvidenceSet
    var sourceRevision: AgentSourceRevision
}

private enum AmbiguityKey: Hashable, Sendable {
    case process(AgentProcessInstanceIdentity)
    case session(AgentProviderSessionIdentity)
}

private struct SourceLedger: Sendable {
    var lastSequence: UInt64 = 0
    var accepted: [UInt64: AgentObservationEnvelope] = [:]
    var order: [UInt64] = []
}

private struct MemoryState: Sendable {
    var revision: UInt64 = 0
    var nextMutationOrdinal: UInt64 = 1
    var sessions: [AgentProviderSessionIdentity: SessionRecord] = [:]
    var processes: [AgentProcessInstanceIdentity: ProcessRecord] = [:]
    var bindings: [AgentProcessInstanceIdentity: BindingRecord] = [:]
    var pendingBindings: [AgentProcessInstanceIdentity: PendingBinding] = [:]
    var quarantinedSessions: Set<AgentProviderSessionIdentity> = []
    var ambiguities: [AmbiguityKey: AgentIdentityAmbiguitySnapshot] = [:]
    var didDropAmbiguityDiagnostics = false
    var sourceLedgers: [AgentObservationSourceEpoch: SourceLedger] = [:]
    var attentionSelection = AgentHumanAttentionSelection(
        target: .none,
        selectedAtReceiverMonotonicNs: 0,
        revision: AgentMemoryRevision(rawValue: 0)
    )

    mutating func takeMutationOrdinal() -> UInt64 {
        let result = nextMutationOrdinal
        if nextMutationOrdinal < UInt64.max {
            nextMutationOrdinal += 1
        }
        return result
    }

    mutating func advanceRevision() -> AgentMemoryRevision {
        if revision < UInt64.max { revision += 1 }
        return AgentMemoryRevision(rawValue: revision)
    }
}

private struct BatchPreflight {
    let newEvents: [AgentObservationEnvelope]
    let acceptedThrough: AgentSourceRevision
}

/// Actor-owned canonical reducer. It never performs process inspection, file I/O,
/// networking, UI work, or delivery. Producers submit immutable observations and
/// consumers receive immutable snapshots.
public actor AgentMemoryStore: AgentObservationSink {
    public nonisolated let limits: AgentMemoryLimits

    private let receiverNow: @Sendable () -> UInt64
    private var state = MemoryState()

    public init(
        limits: AgentMemoryLimits = .default,
        receiverMonotonicNow: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.limits = limits
        self.receiverNow = receiverMonotonicNow
    }

    public func ingest(_ batch: AgentObservationBatch) async -> AgentIngestReceipt {
        do {
            let preflight = try preflight(batch)
            guard !preflight.newEvents.isEmpty else {
                return AgentIngestReceipt(
                    status: .replayed,
                    memoryRevision: currentRevision,
                    acceptedThrough: preflight.acceptedThrough
                )
            }

            // Reduce into a value copy. Any validation or capacity failure rejects
            // the complete batch without exposing a partially updated identity map.
            var candidate = state
            var ambiguityCount = 0
            for event in preflight.newEvents {
                try validate(event)
                ambiguityCount += try apply(event, to: &candidate)
                record(event, in: &candidate)
            }
            let revision = candidate.advanceRevision()
            reconcileSelection(in: &candidate, revision: revision)
            state = candidate

            return AgentIngestReceipt(
                status: ambiguityCount == 0 ? .accepted : .acceptedWithAmbiguity,
                memoryRevision: revision,
                acceptedThrough: preflight.acceptedThrough,
                ambiguityCount: ambiguityCount
            )
        } catch let rejection as AgentIngestRejection {
            return AgentIngestReceipt(
                status: .rejected,
                memoryRevision: currentRevision,
                rejection: rejection
            )
        } catch {
            return AgentIngestReceipt(
                status: .rejected,
                memoryRevision: currentRevision,
                rejection: .invalidIdentity(field: "event")
            )
        }
    }

    /// Explicit human choice. Selection by worktree, label, TTY, or PID is not
    /// offered: only an exact, unambiguous, currently live provider session may be
    /// selected.
    public func selectAttention(
        _ target: AgentHumanAttentionTarget
    ) -> AgentAttentionSelectionResult {
        switch target {
        case .none:
            let revision = state.advanceRevision()
            let selection = AgentHumanAttentionSelection(
                target: .none,
                selectedAtReceiverMonotonicNs: receiverNow(),
                revision: revision
            )
            state.attentionSelection = selection
            return .selected(selection)

        case let .session(identity):
            guard state.sessions[identity] != nil else {
                return .unavailable(.sessionNotFound)
            }
            guard !state.quarantinedSessions.contains(identity) else {
                return .unavailable(.identityAmbiguous)
            }
            guard aggregateLiveness(for: identity, in: state).state == .live else {
                return .unavailable(.sessionNotLive)
            }
            let revision = state.advanceRevision()
            let selection = AgentHumanAttentionSelection(
                target: target,
                selectedAtReceiverMonotonicNs: receiverNow(),
                revision: revision
            )
            state.attentionSelection = selection
            return .selected(selection)
        }
    }

    public func shelfSnapshot() -> AgentShelfSnapshot {
        makeSnapshot(from: state, generatedAt: receiverNow())
    }

    public var currentRevision: AgentMemoryRevision {
        AgentMemoryRevision(rawValue: state.revision)
    }

    // MARK: Batch preflight and validation

    private func preflight(_ batch: AgentObservationBatch) throws -> BatchPreflight {
        guard let first = batch.events.first, let last = batch.events.last else {
            throw AgentIngestRejection.emptyBatch
        }
        guard batch.events.count <= limits.maximumEventsPerBatch else {
            throw AgentIngestRejection.batchLimitExceeded(
                maximum: limits.maximumEventsPerBatch,
                actual: batch.events.count
            )
        }

        let epoch = first.revision.sourceEpoch
        guard batch.events.allSatisfy({ $0.revision.sourceEpoch == epoch }) else {
            throw AgentIngestRejection.mixedSourceEpoch
        }
        if state.sourceLedgers[epoch] == nil,
           state.sourceLedgers.count >= limits.maximumSourceEpochs
        {
            throw AgentIngestRejection.sourceLimitExceeded(
                maximum: limits.maximumSourceEpochs
            )
        }

        let ledger = state.sourceLedgers[epoch] ?? SourceLedger()
        var expected = ledger.lastSequence == UInt64.max
            ? UInt64.max
            : ledger.lastSequence + 1
        var previousInBatch: UInt64?
        var newEvents: [AgentObservationEnvelope] = []

        for event in batch.events {
            let sequence = event.revision.sequence
            guard sequence > 0 else { throw AgentIngestRejection.invalidRevision }
            if let previousInBatch, sequence <= previousInBatch {
                throw AgentIngestRejection.outOfOrder(
                    previous: previousInBatch,
                    found: sequence
                )
            }
            previousInBatch = sequence

            if sequence <= ledger.lastSequence {
                guard let accepted = ledger.accepted[sequence] else {
                    throw AgentIngestRejection.outOfOrder(
                        previous: ledger.lastSequence,
                        found: sequence
                    )
                }
                guard accepted == event else {
                    throw AgentIngestRejection.revisionEquivocation(sequence: sequence)
                }
                continue
            }

            guard sequence == expected else {
                throw AgentIngestRejection.revisionGap(
                    expected: expected,
                    found: sequence
                )
            }
            newEvents.append(event)
            if expected < UInt64.max { expected += 1 }
        }

        return BatchPreflight(newEvents: newEvents, acceptedThrough: last.revision)
    }

    private func validate(_ event: AgentObservationEnvelope) throws {
        guard event.revision.sequence > 0 else {
            throw AgentIngestRejection.invalidRevision
        }
        switch event.payload {
        case let .session(observation):
            try validate(observation.identity)
            try validate(observation.evidence, field: "session.evidence")
            guard observation.evidence.confidence >= .corroborated else {
                throw AgentIngestRejection.insufficientIdentityEvidence
            }
            try validateOptional(
                observation.displayLabel,
                maximum: limits.maximumLabelBytes,
                field: "session.displayLabel"
            )
            try validateOptionalPath(
                observation.canonicalWorkingDirectory,
                field: "session.canonicalWorkingDirectory"
            )
            try validateOptionalPath(
                observation.canonicalWorktreeRoot,
                field: "session.canonicalWorktreeRoot"
            )
            try validateOptional(
                observation.boundedUserPrompt,
                maximum: limits.maximumPreviewBytes,
                field: "session.boundedUserPrompt"
            )
            try validateOptional(
                observation.boundedAssistantPreview,
                maximum: limits.maximumPreviewBytes,
                field: "session.boundedAssistantPreview"
            )

        case let .process(observation):
            try validate(observation.process)
            try validate(observation.evidence, field: "process.evidence")

        case let .processSessionBinding(observation):
            try validate(observation.process)
            try validate(observation.evidence, field: "binding.evidence")
            guard observation.candidateSessions.count <= limits.maximumBindingCandidates else {
                throw AgentIngestRejection.fieldLimitExceeded(
                    field: "binding.candidateSessions",
                    maximum: limits.maximumBindingCandidates,
                    actual: observation.candidateSessions.count
                )
            }
            var seen = Set<AgentProviderSessionIdentity>()
            for identity in observation.candidateSessions {
                try validate(identity)
                guard seen.insert(identity).inserted else {
                    throw AgentIngestRejection.invalidIdentity(
                        field: "binding.candidateSessions"
                    )
                }
            }
        }
    }

    private func validate(_ identity: AgentProviderSessionIdentity) throws {
        let nativeID = identity.nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nativeID.isEmpty else {
            throw AgentIngestRejection.invalidIdentity(field: "session.nativeSessionID")
        }
        guard nativeID.utf8.count <= limits.maximumIdentifierBytes else {
            throw AgentIngestRejection.fieldLimitExceeded(
                field: "session.nativeSessionID",
                maximum: limits.maximumIdentifierBytes,
                actual: nativeID.utf8.count
            )
        }
        if case let .other(identifier) = identity.provider {
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= limits.maximumIdentifierBytes else {
                throw AgentIngestRejection.invalidIdentity(field: "session.provider")
            }
        }
    }

    private func validate(_ identity: AgentProcessInstanceIdentity) throws {
        guard identity.pid > 0 else {
            throw AgentIngestRejection.invalidProcess(field: "process.pid")
        }
        guard identity.startedAtUnixNs > 0 else {
            throw AgentIngestRejection.invalidProcess(field: "process.startedAtUnixNs")
        }
    }

    private func validate(_ process: AgentProcessInstance) throws {
        try validate(process.identity)
        if let parentPID = process.parentPID, parentPID <= 0 {
            throw AgentIngestRejection.invalidProcess(field: "process.parentPID")
        }
        try validateOptionalPath(process.executablePath, field: "process.executablePath")
        try validateOptionalPath(
            process.canonicalWorkingDirectory,
            field: "process.canonicalWorkingDirectory"
        )
        try validateOptional(
            process.tty,
            maximum: limits.maximumIdentifierBytes,
            field: "process.tty"
        )
    }

    private func validate(_ evidence: AgentEvidenceSet, field: String) throws {
        guard !evidence.items.isEmpty else {
            throw AgentIngestRejection.invalidEvidence(field: field)
        }
        guard evidence.items.count <= limits.maximumEvidenceItems else {
            throw AgentIngestRejection.fieldLimitExceeded(
                field: field,
                maximum: limits.maximumEvidenceItems,
                actual: evidence.items.count
            )
        }
        for item in evidence.items {
            guard item.observedAtSourceMonotonicNs > 0 else {
                throw AgentIngestRejection.invalidEvidence(field: field)
            }
            if let code = item.detailCode {
                guard !code.isEmpty, code.utf8.count <= 64,
                      code.utf8.allSatisfy(Self.isDiagnosticCodeByte)
                else {
                    throw AgentIngestRejection.invalidEvidence(field: field)
                }
            }
        }
    }

    private static func isDiagnosticCodeByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) ||
            byte == 45 || byte == 46 || byte == 95
    }

    private func validateOptionalPath(_ value: String?, field: String) throws {
        try validateOptional(value, maximum: limits.maximumPathBytes, field: field)
        if let value, !value.isEmpty, !value.hasPrefix("/") {
            throw AgentIngestRejection.invalidIdentity(field: field)
        }
    }

    private func validateOptional(_ value: String?, maximum: Int, field: String) throws {
        guard let value else { return }
        guard !value.isEmpty else {
            throw AgentIngestRejection.invalidIdentity(field: field)
        }
        guard value.utf8.count <= maximum else {
            throw AgentIngestRejection.fieldLimitExceeded(
                field: field,
                maximum: maximum,
                actual: value.utf8.count
            )
        }
    }

    // MARK: Reduction

    private func apply(
        _ event: AgentObservationEnvelope,
        to candidate: inout MemoryState
    ) throws -> Int {
        switch event.payload {
        case let .session(observation):
            return try apply(observation, revision: event.revision, to: &candidate)
        case let .process(observation):
            try apply(observation, revision: event.revision, to: &candidate)
            return 0
        case let .processSessionBinding(observation):
            return try apply(observation, revision: event.revision, to: &candidate)
        }
    }

    private func apply(
        _ observation: AgentSessionObservation,
        revision: AgentSourceRevision,
        to candidate: inout MemoryState
    ) throws -> Int {
        let identity = observation.identity
        if var record = candidate.sessions[identity] {
            if let oldRoot = record.canonicalWorktreeRoot,
               let newRoot = observation.canonicalWorktreeRoot,
               oldRoot != newRoot
            {
                candidate.quarantinedSessions.insert(identity)
                candidate.bindings = candidate.bindings.filter { $0.value.session != identity }
                addAmbiguity(
                    key: .session(identity),
                    snapshot: AgentIdentityAmbiguitySnapshot(
                        process: nil,
                        candidateSessions: [identity],
                        reason: .conflictingSessionWorktree,
                        evidence: observation.evidence,
                        sourceRevision: revision
                    ),
                    to: &candidate
                )
                return 1
            }

            guard !candidate.quarantinedSessions.contains(identity) else { return 1 }
            record.displayLabel = observation.displayLabel ?? record.displayLabel
            record.canonicalWorkingDirectory = observation.canonicalWorkingDirectory
                ?? record.canonicalWorkingDirectory
            record.canonicalWorktreeRoot = observation.canonicalWorktreeRoot
                ?? record.canonicalWorktreeRoot
            record.boundedUserPrompt = observation.boundedUserPrompt
                ?? record.boundedUserPrompt
            record.boundedAssistantPreview = observation.boundedAssistantPreview
                ?? record.boundedAssistantPreview
            record.boundedUserImageAttachments = observation.boundedUserImageAttachments
            record.boundedAssistantImageAttachments = observation.boundedAssistantImageAttachments
            if observation.evidence.confidence >= record.identityEvidence.confidence {
                record.identityEvidence = observation.evidence
            }
            if observation.evidence.confidence >= record.executionEvidence.confidence {
                record.execution = observation.execution
                record.executionEvidence = observation.evidence
            }
            if observation.evidence.confidence >= record.attentionEvidence.confidence {
                record.attentionDemand = observation.attentionDemand
                record.attentionEvidence = observation.evidence
            }
            record.sourceRevision = revision
            record.lastMutationOrdinal = candidate.takeMutationOrdinal()
            candidate.sessions[identity] = record
        } else {
            guard candidate.sessions.count < limits.maximumSessions else {
                throw AgentIngestRejection.capacityExceeded(
                    resource: "sessions",
                    maximum: limits.maximumSessions
                )
            }
            candidate.sessions[identity] = SessionRecord(
                identity: identity,
                displayLabel: observation.displayLabel,
                canonicalWorkingDirectory: observation.canonicalWorkingDirectory,
                canonicalWorktreeRoot: observation.canonicalWorktreeRoot,
                execution: observation.execution,
                attentionDemand: observation.attentionDemand,
                boundedUserPrompt: observation.boundedUserPrompt,
                boundedAssistantPreview: observation.boundedAssistantPreview,
                boundedUserImageAttachments: observation.boundedUserImageAttachments,
                boundedAssistantImageAttachments: observation.boundedAssistantImageAttachments,
                identityEvidence: observation.evidence,
                executionEvidence: observation.evidence,
                attentionEvidence: observation.evidence,
                sourceRevision: revision,
                lastMutationOrdinal: candidate.takeMutationOrdinal()
            )
        }

        // A unique binding may arrive before its transcript observation. Resolve it
        // only now that the exact provider session exists and remains unambiguous.
        let ready = candidate.pendingBindings.compactMap { process, pending in
            pending.candidates.count == 1 && pending.candidates[0] == identity &&
                pending.evidence.confidence >= .corroborated
                ? process
                : nil
        }
        for process in ready {
            guard let pending = candidate.pendingBindings.removeValue(forKey: process),
                  candidate.processes[process] != nil
            else { continue }
            candidate.bindings[process] = BindingRecord(
                session: identity,
                evidence: pending.evidence,
                sourceRevision: pending.sourceRevision
            )
            candidate.ambiguities.removeValue(forKey: .process(process))
        }
        return 0
    }

    private func apply(
        _ observation: AgentProcessObservation,
        revision: AgentSourceRevision,
        to candidate: inout MemoryState
    ) throws {
        let identity = observation.process.identity
        if var record = candidate.processes[identity] {
            if observation.evidence.confidence >= record.evidence.confidence {
                record.process = observation.process
                record.liveness = observation.liveness
                record.evidence = observation.evidence
                record.sourceRevision = revision
            }
            record.lastMutationOrdinal = candidate.takeMutationOrdinal()
            candidate.processes[identity] = record
        } else {
            guard candidate.processes.count < limits.maximumProcesses else {
                throw AgentIngestRejection.capacityExceeded(
                    resource: "processes",
                    maximum: limits.maximumProcesses
                )
            }
            candidate.processes[identity] = ProcessRecord(
                process: observation.process,
                liveness: observation.liveness,
                evidence: observation.evidence,
                sourceRevision: revision,
                lastMutationOrdinal: candidate.takeMutationOrdinal()
            )
        }
    }

    private func apply(
        _ observation: AgentProcessSessionBindingObservation,
        revision: AgentSourceRevision,
        to candidate: inout MemoryState
    ) throws -> Int {
        let process = observation.process
        guard candidate.processes[process] != nil else {
            throw AgentIngestRejection.processUnavailable
        }

        let candidates = observation.candidateSessions
        if let existing = candidate.bindings[process] {
            if candidates.count == 1, candidates[0] == existing.session {
                if observation.evidence.confidence >= existing.evidence.confidence {
                    candidate.bindings[process] = BindingRecord(
                        session: existing.session,
                        evidence: observation.evidence,
                        sourceRevision: revision
                    )
                }
                return 0
            }
            // Lower-confidence disagreement cannot erase a stronger exact join.
            guard observation.evidence.confidence >= existing.evidence.confidence else {
                return 0
            }
            let allCandidates = Array(Set(candidates + [existing.session])).sorted(
                by: Self.identityPrecedes
            )
            candidate.bindings.removeValue(forKey: process)
            candidate.pendingBindings[process] = PendingBinding(
                candidates: allCandidates,
                evidence: observation.evidence,
                sourceRevision: revision
            )
            addAmbiguity(
                key: .process(process),
                snapshot: AgentIdentityAmbiguitySnapshot(
                    process: process,
                    candidateSessions: allCandidates,
                    reason: .conflictingProcessBinding,
                    evidence: observation.evidence,
                    sourceRevision: revision
                ),
                to: &candidate
            )
            return 1
        }

        guard candidates.count == 1,
              observation.evidence.confidence >= .corroborated
        else {
            candidate.bindings.removeValue(forKey: process)
            candidate.pendingBindings[process] = PendingBinding(
                candidates: candidates,
                evidence: observation.evidence,
                sourceRevision: revision
            )
            let reason: AgentIdentityAmbiguityReason = candidates.count > 1
                ? .multipleCandidateSessions
                : .insufficientEvidence
            addAmbiguity(
                key: .process(process),
                snapshot: AgentIdentityAmbiguitySnapshot(
                    process: process,
                    candidateSessions: candidates,
                    reason: reason,
                    evidence: observation.evidence,
                    sourceRevision: revision
                ),
                to: &candidate
            )
            return 1
        }

        let session = candidates[0]
        guard candidate.sessions[session] != nil,
              !candidate.quarantinedSessions.contains(session)
        else {
            candidate.pendingBindings[process] = PendingBinding(
                candidates: candidates,
                evidence: observation.evidence,
                sourceRevision: revision
            )
            if candidate.quarantinedSessions.contains(session) {
                addAmbiguity(
                    key: .process(process),
                    snapshot: AgentIdentityAmbiguitySnapshot(
                        process: process,
                        candidateSessions: candidates,
                        reason: .conflictingSessionWorktree,
                        evidence: observation.evidence,
                        sourceRevision: revision
                    ),
                    to: &candidate
                )
                return 1
            }
            return 0
        }

        candidate.pendingBindings.removeValue(forKey: process)
        candidate.ambiguities.removeValue(forKey: .process(process))
        candidate.bindings[process] = BindingRecord(
            session: session,
            evidence: observation.evidence,
            sourceRevision: revision
        )
        return 0
    }

    private func addAmbiguity(
        key: AmbiguityKey,
        snapshot: AgentIdentityAmbiguitySnapshot,
        to candidate: inout MemoryState
    ) {
        if candidate.ambiguities[key] == nil,
           candidate.ambiguities.count >= limits.maximumAmbiguityDiagnostics
        {
            candidate.didDropAmbiguityDiagnostics = true
            return
        }
        candidate.ambiguities[key] = snapshot
    }

    private func record(_ event: AgentObservationEnvelope, in candidate: inout MemoryState) {
        let epoch = event.revision.sourceEpoch
        var ledger = candidate.sourceLedgers[epoch] ?? SourceLedger()
        ledger.lastSequence = event.revision.sequence
        ledger.accepted[event.revision.sequence] = event
        ledger.order.append(event.revision.sequence)
        while ledger.order.count > limits.maximumReplayEntriesPerSource {
            let sequence = ledger.order.removeFirst()
            ledger.accepted.removeValue(forKey: sequence)
        }
        candidate.sourceLedgers[epoch] = ledger
    }

    // MARK: Snapshot construction

    private func reconcileSelection(
        in candidate: inout MemoryState,
        revision: AgentMemoryRevision
    ) {
        guard case let .session(identity) = candidate.attentionSelection.target else {
            return
        }
        let valid = candidate.sessions[identity] != nil &&
            !candidate.quarantinedSessions.contains(identity) &&
            aggregateLiveness(for: identity, in: candidate).state == .live
        guard !valid else { return }
        candidate.attentionSelection = AgentHumanAttentionSelection(
            target: .none,
            selectedAtReceiverMonotonicNs: receiverNow(),
            revision: revision
        )
    }

    private func makeSnapshot(
        from state: MemoryState,
        generatedAt: UInt64
    ) -> AgentShelfSnapshot {
        let memoryRevision = AgentMemoryRevision(rawValue: state.revision)
        let sessions = state.sessions.values
            .filter { !state.quarantinedSessions.contains($0.identity) }
            .sorted { Self.identityPrecedes($0.identity, $1.identity) }
            .map { record in
                let processes = processSnapshots(for: record.identity, in: state)
                let liveness = aggregateLiveness(from: processes)
                return AgentSessionSnapshot(
                    identity: record.identity,
                    displayLabel: record.displayLabel,
                    canonicalWorkingDirectory: record.canonicalWorkingDirectory,
                    canonicalWorktreeRoot: record.canonicalWorktreeRoot,
                    liveness: liveness.state,
                    execution: record.execution,
                    attentionDemand: record.attentionDemand,
                    boundedUserPrompt: record.boundedUserPrompt,
                    boundedAssistantPreview: record.boundedAssistantPreview,
                    boundedUserImageAttachments: record.boundedUserImageAttachments,
                    boundedAssistantImageAttachments: record.boundedAssistantImageAttachments,
                    processes: processes,
                    identityEvidence: record.identityEvidence,
                    livenessEvidence: liveness.evidence,
                    executionEvidence: record.executionEvidence,
                    attentionEvidence: record.attentionEvidence,
                    sourceRevision: record.sourceRevision,
                    memoryRevision: memoryRevision
                )
            }

        let ambiguities = state.ambiguities.values.sorted { lhs, rhs in
            let left = lhs.candidateSessions.first
            let right = rhs.candidateSessions.first
            switch (left, right) {
            case let (left?, right?): return Self.identityPrecedes(left, right)
            case (nil, nil):
                return (lhs.process?.pid ?? 0) < (rhs.process?.pid ?? 0)
            case (nil, _): return true
            case (_, nil): return false
            }
        }

        return AgentShelfSnapshot(
            revision: memoryRevision,
            generatedAtReceiverMonotonicNs: generatedAt,
            sessions: sessions,
            ambiguities: ambiguities,
            attentionSelection: state.attentionSelection,
            didDropAmbiguityDiagnostics: state.didDropAmbiguityDiagnostics
        )
    }

    private func processSnapshots(
        for session: AgentProviderSessionIdentity,
        in state: MemoryState
    ) -> [AgentProcessSnapshot] {
        state.bindings.compactMap { process, binding in
            guard binding.session == session, let record = state.processes[process] else {
                return nil
            }
            return AgentProcessSnapshot(
                process: record.process,
                liveness: record.liveness,
                livenessEvidence: record.evidence,
                sourceRevision: record.sourceRevision
            )
        }.sorted { lhs, rhs in
            let left = lhs.process.identity
            let right = rhs.process.identity
            if left.hostBootID != right.hostBootID {
                return left.hostBootID.uuidString < right.hostBootID.uuidString
            }
            if left.pid != right.pid { return left.pid < right.pid }
            return left.startedAtUnixNs < right.startedAtUnixNs
        }
    }

    private func aggregateLiveness(
        for session: AgentProviderSessionIdentity,
        in state: MemoryState
    ) -> (state: AgentLiveness, evidence: AgentEvidenceSet) {
        aggregateLiveness(from: processSnapshots(for: session, in: state))
    }

    private func aggregateLiveness(
        from processes: [AgentProcessSnapshot]
    ) -> (state: AgentLiveness, evidence: AgentEvidenceSet) {
        let relevant: [AgentProcessSnapshot]
        let result: AgentLiveness
        if processes.contains(where: { $0.liveness == .live }) {
            result = .live
            relevant = processes.filter { $0.liveness == .live }
        } else if !processes.isEmpty,
                  processes.allSatisfy({ $0.liveness == .notRunning })
        {
            result = .notRunning
            relevant = processes
        } else {
            result = .unknown
            relevant = processes
        }

        let confidence = relevant.map(\.livenessEvidence.confidence).max() ?? .weak
        var seen = Set<AgentEvidence>()
        var items: [AgentEvidence] = []
        for process in relevant {
            for item in process.livenessEvidence.items where seen.insert(item).inserted {
                guard items.count < limits.maximumEvidenceItems else { break }
                items.append(item)
            }
        }
        return (result, AgentEvidenceSet(confidence: confidence, items: items))
    }

    private static func identityPrecedes(
        _ lhs: AgentProviderSessionIdentity,
        _ rhs: AgentProviderSessionIdentity
    ) -> Bool {
        if lhs.provider.stableIdentifier != rhs.provider.stableIdentifier {
            return lhs.provider.stableIdentifier < rhs.provider.stableIdentifier
        }
        return lhs.nativeSessionID < rhs.nativeSessionID
    }
}
