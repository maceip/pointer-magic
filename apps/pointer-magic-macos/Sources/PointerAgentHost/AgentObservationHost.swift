import CryptoKit
import Darwin
import Dispatch
import Foundation
import PointerAgentContracts
import PointerAgentMemory
import PointerMacAgentDiscovery

public struct AgentObservationHostStatus: Hashable, Sendable {
    public let discoveryRevision: UInt64
    public let discoveredProcessCount: Int
    public let exactSessionCount: Int
    public let discoveryGapCount: Int
    public let lastIngestStatus: AgentIngestStatus?
    public let lastIngestRejection: AgentIngestRejection?

    public init(
        discoveryRevision: UInt64 = 0,
        discoveredProcessCount: Int = 0,
        exactSessionCount: Int = 0,
        discoveryGapCount: Int = 0,
        lastIngestStatus: AgentIngestStatus? = nil,
        lastIngestRejection: AgentIngestRejection? = nil
    ) {
        self.discoveryRevision = discoveryRevision
        self.discoveredProcessCount = discoveredProcessCount
        self.exactSessionCount = exactSessionCount
        self.discoveryGapCount = discoveryGapCount
        self.lastIngestStatus = lastIngestStatus
        self.lastIngestRejection = lastIngestRejection
    }
}

/// Bridges passive macOS discovery into the transport-neutral reducer.
///
/// This actor has observation authority only. It cannot spawn an agent, write to a
/// terminal, focus a window, deliver a prompt, or perform a network request.
public actor AgentObservationHost {
    public nonisolated let mirror: AgentMemorySnapshotMirror
    public let discovery: MacAgentDiscoveryController

    private let sourceEpoch: AgentObservationSourceEpoch
    private let hostBootID: UUID
    private var lastProcessedDiscoveryRevision: UInt64 = 0
    private var lastAcceptedSequence: UInt64 = 0
    private var previousProcesses: [
        PointerMacAgentDiscovery.AgentProcessKey:
            PointerMacAgentDiscovery.AgentProcessSnapshot
    ] = [:]
    private var promptActivationTracker = AgentHumanPromptActivationTracker()
    private var worktreeCache: [String: String?] = [:]
    private var observationTask: Task<Void, Never>?
    private var statusValue = AgentObservationHostStatus()
    private var snapshotContinuations: [
        UUID: AsyncStream<AgentShelfSnapshot>.Continuation
    ] = [:]

    public init(
        discovery: MacAgentDiscoveryController = MacAgentDiscoveryController(),
        store: AgentMemoryStore = AgentMemoryStore()
    ) {
        self.discovery = discovery
        mirror = AgentMemorySnapshotMirror(store: store)
        sourceEpoch = AgentObservationSourceEpoch(
            sourceID: AgentObservationSourceID(),
            epochID: UUID()
        )
        hostBootID = HostBootIdentity.current()
    }

    public func start() async {
        guard observationTask == nil else { return }
        let updates = await discovery.updates()
        await discovery.start()
        observationTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled, let self else { break }
                await self.accept(snapshot)
            }
        }
    }

    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        await discovery.stop()
        for continuation in snapshotContinuations.values {
            continuation.finish()
        }
        snapshotContinuations.removeAll(keepingCapacity: false)
    }

    /// Runs the same real passive census used by the background loop. This exists
    /// for deterministic startup and diagnostics; it does not use fixture state.
    @discardableResult
    public func refreshNow() async -> AgentShelfSnapshot {
        let snapshot = await discovery.refresh()
        await accept(snapshot)
        return mirror.cachedSnapshot()
    }

    public nonisolated func cachedSnapshot() -> AgentShelfSnapshot {
        mirror.cachedSnapshot()
    }

    public func status() -> AgentObservationHostStatus { statusValue }

    public func updates() -> AsyncStream<AgentShelfSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuations[id] = continuation
            continuation.yield(mirror.cachedSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func accept(_ snapshot: MacAgentDiscoverySnapshot) async {
        // `updates()` yields its initial empty value. It is not evidence that every
        // previously observed process died. `refreshNow()` can also receive the same
        // revision already yielded by the updates stream, so each discovery revision
        // is reduced exactly once.
        guard snapshot.revision > lastProcessedDiscoveryRevision else { return }
        lastProcessedDiscoveryRevision = snapshot.revision

        let now = DispatchTime.now().uptimeNanoseconds
        let memoryLimits = mirror.store.limits
        let transcriptByPath = Dictionary(
            uniqueKeysWithValues: snapshot.transcripts.map { ($0.path, $0) }
        )
        let currentProcesses = Dictionary(
            uniqueKeysWithValues: snapshot.processes.map { ($0.key, $0) }
        )
        var payloads: [AgentObservationPayload] = []

        for process in snapshot.processes {
            payloads.append(.process(processObservation(
                process,
                liveness: .live,
                observedAt: now
            )))
        }
        let censusIsComplete = !snapshot.gaps.contains { gap in
            gap.kind == .processListTruncated || gap.kind == .candidateProcessLimitReached
        }
        if censusIsComplete {
            for (key, process) in previousProcesses where currentProcesses[key] == nil {
                payloads.append(.process(processObservation(
                    process,
                    liveness: .notRunning,
                    observedAt: now
                )))
            }
        }

        let correlationsByProcess = Dictionary(grouping: snapshot.sessions, by: \.process)
        var emittedSessions = Set<AgentProviderSessionIdentity>()
        var attentionCandidates: [AgentHumanPromptActivationCandidate] = []

        for (processKey, correlations) in correlationsByProcess {
            let strong = correlations.filter {
                guard let evidence = $0.correlation?.evidence else { return false }
                return evidence == .openTranscriptFile || evidence == .explicitSessionArgument
            }
            let identities = Array(Set(strong.compactMap(contractIdentity))).sorted {
                if $0.provider.stableIdentifier != $1.provider.stableIdentifier {
                    return $0.provider.stableIdentifier < $1.provider.stableIdentifier
                }
                return $0.nativeSessionID < $1.nativeSessionID
            }

            for correlation in strong {
                guard let identity = contractIdentity(correlation),
                      emittedSessions.insert(identity).inserted,
                      let path = correlation.transcriptPath,
                      let transcript = transcriptByPath[path]
                else { continue }

                let evidence = evidenceSet(
                    for: correlation.correlation?.evidence,
                    observedAt: now
                )
                let cwd = boundedHostAbsolutePath(
                    correlation.cwd ?? transcript.cwd,
                    maximumBytes: memoryLimits.maximumPathBytes
                )
                let state = executionState(for: transcript)
                payloads.append(.session(AgentSessionObservation(
                    identity: identity,
                    displayLabel: boundedHostUTF8(
                        displayLabel(for: identity, cwd: cwd),
                        maximumBytes: memoryLimits.maximumLabelBytes
                    ),
                    canonicalWorkingDirectory: cwd,
                    canonicalWorktreeRoot: boundedHostAbsolutePath(
                        worktreeRoot(for: cwd),
                        maximumBytes: memoryLimits.maximumPathBytes
                    ),
                    execution: state.execution,
                    attentionDemand: state.demand,
                    boundedUserPrompt: boundedHostUTF8(
                        transcript.latestUserPrompt?.text,
                        maximumBytes: memoryLimits.maximumPreviewBytes
                    ),
                    boundedAssistantPreview: boundedHostUTF8(
                        transcript.latestAssistantText?.text,
                        maximumBytes: memoryLimits.maximumPreviewBytes
                    ),
                    boundedUserImageAttachments: imageAttachments(
                        transcript.latestUserPrompt?.imageAttachments,
                        provider: identity.provider,
                        sessionID: identity.nativeSessionID
                    ),
                    boundedAssistantImageAttachments: imageAttachments(
                        transcript.latestAssistantText?.imageAttachments,
                        provider: identity.provider,
                        sessionID: identity.nativeSessionID
                    ),
                    evidence: evidence
                )))

                if correlation.isUniquelyAddressed,
                   let prompt = transcript.latestUserPrompt
                {
                    attentionCandidates.append(AgentHumanPromptActivationCandidate(
                        identity: identity,
                        cursor: AgentHumanPromptCursor(
                            device: transcript.fileIdentity.device,
                            inode: transcript.fileIdentity.inode,
                            sourceOffset: prompt.sourceOffset
                        ),
                        timestampUnixNs: prompt.timestampUnixNs
                            ?? transcript.fileIdentity.modificationTimeUnixNs
                    ))
                }
            }

            guard let discoveredProcess = currentProcesses[processKey], !identities.isEmpty else {
                continue
            }
            let strongestEvidence = strong.compactMap(\.correlation?.evidence).contains(
                .openTranscriptFile
            ) ? AgentSessionCorrelationEvidence.openTranscriptFile : .explicitSessionArgument
            payloads.append(.processSessionBinding(
                AgentProcessSessionBindingObservation(
                    process: contractProcessIdentity(discoveredProcess.key),
                    candidateSessions: identities,
                    evidence: evidenceSet(for: strongestEvidence, observedAt: now)
                )
            ))
        }

        var lastStatus: AgentIngestStatus?
        var lastRejection: AgentIngestRejection?
        var didCommitEveryPayload = true
        // Reduce through the store without publishing a shelf snapshot per chunk.
        // One synchronize + one UI yield happens after the full discovery revision commits.
        for payloadChunk in payloads.chunked(maximumCount: 192) {
            let events = payloadChunk.enumerated().map { index, payload in
                AgentObservationEnvelope(
                    revision: AgentSourceRevision(
                        sourceEpoch: sourceEpoch,
                        sequence: lastAcceptedSequence + UInt64(index) + 1
                    ),
                    payload: payload
                )
            }
            guard !events.isEmpty else { continue }
            let receipt = await mirror.store.ingest(AgentObservationBatch(events: events))
            lastStatus = receipt.status
            lastRejection = receipt.rejection
            guard receipt.status != .rejected else {
                didCommitEveryPayload = false
                break
            }
            lastAcceptedSequence += UInt64(events.count)
        }

        if didCommitEveryPayload {
            if censusIsComplete {
                previousProcesses = currentProcesses
            } else {
                previousProcesses.merge(currentProcesses) { _, current in current }
            }

            // Human prompt evidence is the only automatic selector. A transcript-local
            // cursor change, not a global wall-clock comparison, proves which session the
            // person just typed into. Timestamps only break ties when one discovery pass
            // observes more than one changed prompt. A newly discovered session is seeded
            // silently unless its prompt is newer than the previous committed census.
            let newest = promptActivationTracker.winner(among: attentionCandidates)
            var didSelectNewest = false
            if let newest,
               case .selected = await mirror.selectAttention(.session(newest.identity))
            {
                didSelectNewest = true
            } else {
                _ = await mirror.synchronizeSnapshot()
            }
            promptActivationTracker.commit(
                attentionCandidates,
                winner: newest,
                selectionSucceeded: didSelectNewest,
                discoveryObservedAtUnixNs: snapshot.observedAtUnixNs
            )
        }

        statusValue = AgentObservationHostStatus(
            discoveryRevision: snapshot.revision,
            discoveredProcessCount: snapshot.processes.count,
            exactSessionCount: snapshot.sessions.filter(\.isUniquelyAddressed).count,
            discoveryGapCount: snapshot.gaps.count,
            lastIngestStatus: lastStatus,
            lastIngestRejection: lastRejection
        )
        if didCommitEveryPayload {
            let reduced = mirror.cachedSnapshot()
            for continuation in snapshotContinuations.values {
                continuation.yield(reduced)
            }
        }
    }

    private func processObservation(
        _ process: PointerMacAgentDiscovery.AgentProcessSnapshot,
        liveness: AgentLiveness,
        observedAt: UInt64
    ) -> AgentProcessObservation {
        AgentProcessObservation(
            process: AgentProcessInstance(
                identity: contractProcessIdentity(process.key),
                parentPID: process.parentPID > 0 ? process.parentPID : nil,
                executablePath: process.executablePath.isEmpty ? nil : process.executablePath,
                canonicalWorkingDirectory: process.cwd,
                tty: process.controllingTTY
            ),
            liveness: liveness,
            evidence: AgentEvidenceSet(
                confidence: .authoritative,
                items: [AgentEvidence(
                    kind: .processTable,
                    observedAtSourceMonotonicNs: observedAt,
                    detailCode: liveness == .live ? "native-census-live" : "native-census-gone"
                )]
            )
        )
    }

    private func contractProcessIdentity(
        _ value: PointerMacAgentDiscovery.AgentProcessKey
    ) -> AgentProcessInstanceIdentity {
        AgentProcessInstanceIdentity(
            hostBootID: hostBootID,
            pid: value.pid,
            startedAtUnixNs: value.startTimeUnixNs
        )
    }

    private func contractIdentity(
        _ value: DiscoveredAgentSession
    ) -> AgentProviderSessionIdentity? {
        guard let nativeSessionID = value.providerSessionID, !nativeSessionID.isEmpty else {
            return nil
        }
        let provider: PointerAgentContracts.AgentProvider = switch value.provider {
        case .codex: .codex
        case .claude: .claudeCode
        case .cursor: .cursor
        }
        return AgentProviderSessionIdentity(
            provider: provider,
            nativeSessionID: nativeSessionID
        )
    }

    private func imageAttachments(
        _ attachments: [AgentTranscriptImageAttachment]?,
        provider: PointerAgentContracts.AgentProvider,
        sessionID: String
    ) -> [AgentImageAttachment] {
        (attachments ?? []).prefix(4).map { attachment in
            AgentImageAttachment(
                identifier: provider.stableIdentifier + ":" + sessionID + ":" +
                    attachment.identifier,
                sourceLocalFilePath: attachment.localFilePath,
                displayName: URL(fileURLWithPath: attachment.localFilePath).lastPathComponent
            )
        }
    }

    private func evidenceSet(
        for evidence: AgentSessionCorrelationEvidence?,
        observedAt: UInt64
    ) -> AgentEvidenceSet {
        switch evidence {
        case .openTranscriptFile:
            AgentEvidenceSet(
                confidence: .authoritative,
                items: [
                    AgentEvidence(
                        kind: .providerTranscript,
                        observedAtSourceMonotonicNs: observedAt,
                        detailCode: "canonical-root-transcript"
                    ),
                    AgentEvidence(
                        kind: .openTranscriptFile,
                        observedAtSourceMonotonicNs: observedAt,
                        detailCode: "exact-process-open-file"
                    ),
                ]
            )
        case .explicitSessionArgument:
            AgentEvidenceSet(
                confidence: .corroborated,
                items: [
                    AgentEvidence(
                        kind: .providerTranscript,
                        observedAtSourceMonotonicNs: observedAt,
                        detailCode: "canonical-root-transcript"
                    ),
                    AgentEvidence(
                        kind: .processCommandLine,
                        observedAtSourceMonotonicNs: observedAt,
                        detailCode: "explicit-session-argument"
                    ),
                ]
            )
        case .workspaceAndTimeCandidate, nil:
            AgentEvidenceSet(
                confidence: .weak,
                items: [AgentEvidence(
                    kind: .terminalAssociation,
                    observedAtSourceMonotonicNs: observedAt,
                    detailCode: "workspace-time-candidate"
                )]
            )
        }
    }

    private func executionState(
        for transcript: AgentTranscriptSnapshot
    ) -> (execution: AgentExecutionState, demand: AgentAttentionDemand) {
        let lifecycle = transcript.recentEvents.last { event in
            event.kind == .userPrompt || event.kind == .turnStarted ||
                event.kind == .turnCompleted || event.kind == .turnAborted
        }
        switch lifecycle?.kind {
        case .userPrompt, .turnStarted:
            return (.working, .none)
        case .turnCompleted:
            return (.completed, .verification)
        case .turnAborted:
            return (.failed, .failure)
        default:
            return (.unknown, .unknown)
        }
    }

    private func displayLabel(
        for identity: AgentProviderSessionIdentity,
        cwd: String?
    ) -> String {
        let provider = switch identity.provider {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .cursor: "Cursor"
        case let .other(value): value
        }
        guard let cwd, !cwd.isEmpty else { return provider }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty ? provider : "\(provider) · \(folder)"
    }

    private func worktreeRoot(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let cached = worktreeCache[cwd] { return cached }
        var candidate = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<32 {
            let marker = candidate.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: marker) {
                let root = candidate.resolvingSymlinksInPath().path
                worktreeCache[cwd] = root
                return root
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        worktreeCache[cwd] = nil
        return nil
    }
}

private enum HostBootIdentity {
    static func current() -> UUID {
        var uuidSize = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &uuidSize, nil, 0) == 0,
           uuidSize > 1
        {
            var uuidBytes = [CChar](repeating: 0, count: uuidSize)
            if sysctlbyname(
                "kern.bootsessionuuid",
                &uuidBytes,
                &uuidSize,
                nil,
                0
            ) == 0
            {
                let end = uuidBytes.firstIndex(of: 0) ?? uuidBytes.endIndex
                let string = String(
                    decoding: uuidBytes[..<end].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                if let value = UUID(uuidString: string) {
                    return value
                }
            }
        }

        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let status = withUnsafeMutablePointer(to: &boot) { pointer in
            sysctlbyname("kern.boottime", pointer, &size, nil, 0)
        }
        let seed = status == 0
            ? "\(boot.tv_sec):\(boot.tv_usec)"
            : "observer:\(ProcessInfo.processInfo.systemUptime)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

func boundedHostUTF8(_ value: String?, maximumBytes: Int) -> String? {
    guard let value, !value.isEmpty, maximumBytes > 0 else { return nil }
    guard value.utf8.count > maximumBytes else { return value }

    var scalars = String.UnicodeScalarView()
    var byteCount = 0
    for scalar in value.unicodeScalars {
        let scalarBytes = scalar.utf8.count
        guard scalarBytes <= maximumBytes - byteCount else { break }
        scalars.append(scalar)
        byteCount += scalarBytes
    }
    let bounded = String(scalars)
    return bounded.isEmpty ? nil : bounded
}

private func boundedHostAbsolutePath(_ value: String?, maximumBytes: Int) -> String? {
    guard let value,
          !value.isEmpty,
          value.hasPrefix("/"),
          value.utf8.count <= maximumBytes
    else { return nil }
    return value
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        let count = Swift.max(1, maximumCount)
        return stride(from: 0, to: self.count, by: count).map { start in
            Array(self[start ..< Swift.min(start + count, self.count)])
        }
    }
}
