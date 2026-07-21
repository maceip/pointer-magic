import Darwin
import Foundation

public struct AgentTranscriptRegistryConfiguration: Hashable, Sendable {
    public let maximumDirectoriesPerScan: Int
    public let maximumFilesPerScan: Int
    public let maximumReadBytesPerFile: Int
    public let startupReplayBytes: UInt64
    public let metadataPrefixBytes: Int
    public let maximumRecordsPerFilePerScan: Int
    public let maximumRecentEventsPerTranscript: Int
    public let maximumTextCharacters: Int
    public let recentFileAgeNs: UInt64

    public init(
        maximumDirectoriesPerScan: Int = 2_048,
        maximumFilesPerScan: Int = 512,
        maximumReadBytesPerFile: Int = 8 * 1_024 * 1_024,
        startupReplayBytes: UInt64 = 8 * 1_024 * 1_024,
        metadataPrefixBytes: Int = 4 * 1_024 * 1_024,
        maximumRecordsPerFilePerScan: Int = 16_384,
        maximumRecentEventsPerTranscript: Int = 64,
        maximumTextCharacters: Int = 16_384,
        recentFileAgeNs: UInt64 = 24 * 60 * 60 * 1_000_000_000
    ) {
        self.maximumDirectoriesPerScan = max(1, min(maximumDirectoriesPerScan, 16_384))
        self.maximumFilesPerScan = max(1, min(maximumFilesPerScan, 4_096))
        self.maximumReadBytesPerFile = max(4_096, min(maximumReadBytesPerFile, 8 * 1_024 * 1_024))
        self.startupReplayBytes = max(4_096, min(startupReplayBytes, 8 * 1_024 * 1_024))
        self.metadataPrefixBytes = max(4_096, min(metadataPrefixBytes, 8 * 1_024 * 1_024))
        self.maximumRecordsPerFilePerScan = max(1, min(maximumRecordsPerFilePerScan, 16_384))
        self.maximumRecentEventsPerTranscript = max(1, min(maximumRecentEventsPerTranscript, 512))
        self.maximumTextCharacters = max(256, min(maximumTextCharacters, 65_536))
        self.recentFileAgeNs = recentFileAgeNs
    }

    public static let `default` = AgentTranscriptRegistryConfiguration()
}

public struct AgentTranscriptRegistryResult: Hashable, Sendable {
    public let transcripts: [AgentTranscriptSnapshot]
    public let gaps: [AgentDiscoveryGap]

    public init(transcripts: [AgentTranscriptSnapshot], gaps: [AgentDiscoveryGap]) {
        self.transcripts = transcripts
        self.gaps = gaps
    }
}

/// Bounded, descriptor-safe transcript discovery. Files are opened only for one read
/// pass and immediately closed; no kqueue/vnode descriptor is retained per session.
/// A future FSEvents hint can call `scan` early, but periodic reconciliation remains
/// authoritative because FSEvents is coalescing and may report only an ancestor path.
public actor AgentTranscriptRegistry {
    private struct FileState: Sendable {
        var device: UInt64
        var inode: UInt64
        var nextOffset: UInt64
        var cwd: String?
        var role: AgentTranscriptRole
        var latestUserPrompt: AgentTranscriptEvent?
        var latestAssistantText: AgentTranscriptEvent?
        var recentEvents: [AgentTranscriptEvent]
        var replayWasTruncated: Bool
        var needsLeadingPartialDiscard: Bool
        var isDiscardingOversizedRecord: Bool
    }

    private struct Candidate: Sendable {
        let path: AgentCanonicalTranscriptPath
        let modificationTimeUnixNs: UInt64
        let priority: Bool
    }

    private struct CursorState: Sendable {
        var cursor: CursorAgentStoreCursor
    }

    public let configuration: AgentTranscriptRegistryConfiguration
    public let cursorReader: CursorAgentStoreReader
    private var states: [String: FileState] = [:]
    private var cursorStates: [String: CursorState] = [:]

    public init(
        configuration: AgentTranscriptRegistryConfiguration = .default,
        cursorReader: CursorAgentStoreReader = CursorAgentStoreReader()
    ) {
        self.configuration = configuration
        self.cursorReader = cursorReader
    }

    public func scan(priorityPaths: Set<String> = []) -> AgentTranscriptRegistryResult {
        let now = agentUnixTimeNs()
        var gaps: [AgentDiscoveryGap] = []
        let priorities = Set(priorityPaths.compactMap {
            AgentCanonicalTranscriptPath.classify($0)?.canonicalPath
        })
        var candidates = discoverCandidates(
            priorityPaths: priorities,
            now: now,
            gaps: &gaps
        )
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority && !$1.priority }
            if $0.modificationTimeUnixNs != $1.modificationTimeUnixNs {
                return $0.modificationTimeUnixNs > $1.modificationTimeUnixNs
            }
            return $0.path.canonicalPath < $1.path.canonicalPath
        }
        if candidates.count > configuration.maximumFilesPerScan {
            candidates.removeLast(candidates.count - configuration.maximumFilesPerScan)
            gaps.append(AgentDiscoveryGap(kind: .transcriptFileLimitReached))
        }

        let retained = Set(candidates.map(\.path.canonicalPath))
        states = states.filter { retained.contains($0.key) }
        cursorStates = cursorStates.filter { retained.contains($0.key) }

        var snapshots: [AgentTranscriptSnapshot] = []
        snapshots.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let result = consume(candidate.path, observedAt: now) else {
                gaps.append(AgentDiscoveryGap(
                    kind: .transcriptUnavailable,
                    subject: candidate.path.canonicalPath
                ))
                continue
            }
            if result.readWasLimited {
                gaps.append(AgentDiscoveryGap(
                    kind: .transcriptReadLimitReached,
                    subject: candidate.path.canonicalPath
                ))
            }
            if result.oversizedRecordWasSkipped {
                gaps.append(AgentDiscoveryGap(
                    kind: .transcriptRecordTooLarge,
                    subject: candidate.path.canonicalPath
                ))
            }
            // Internal Codex subagents are useful parser input but are not user
            // sessions and never leave the registry as routing candidates.
            guard result.snapshot.role != .internalSubagent else { continue }
            snapshots.append(result.snapshot)
        }
        snapshots.sort {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.fileIdentity.modificationTimeUnixNs > $1.fileIdentity.modificationTimeUnixNs
        }
        return AgentTranscriptRegistryResult(transcripts: snapshots, gaps: gaps)
    }

    private func discoverCandidates(
        priorityPaths: Set<String>,
        now: UInt64,
        gaps: inout [AgentDiscoveryGap]
    ) -> [Candidate] {
        var byPath: [String: Candidate] = [:]
        for path in priorityPaths {
            guard let canonical = AgentCanonicalTranscriptPath.classify(path),
                  let identity = fileIdentity(at: path)
            else { continue }
            byPath[path] = Candidate(
                path: canonical,
                modificationTimeUnixNs: identity.modificationTimeUnixNs,
                priority: true
            )
        }

        // Exact open transcript files are the only paths that can become live
        // process bindings. When they exist, do not spend startup I/O replaying a
        // directory of unrelated inactive sessions.
        if !byPath.isEmpty {
            return Array(byPath.values)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true),
        ]
        var directoryCount = 0
        var discoveredFileCount = 0

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .contentModificationDateKey,
                ])
                if values?.isDirectory == true {
                    directoryCount += 1
                    if directoryCount >= configuration.maximumDirectoriesPerScan {
                        enumerator.skipDescendants()
                        gaps.append(AgentDiscoveryGap(kind: .transcriptDirectoryLimitReached))
                        break
                    }
                    continue
                }
                guard values?.isRegularFile == true,
                      url.pathExtension == "jsonl",
                      let canonical = AgentCanonicalTranscriptPath.classify(url.path),
                      let identity = fileIdentity(at: canonical.canonicalPath)
                else { continue }

                discoveredFileCount += 1
                let priority = priorityPaths.contains(canonical.canonicalPath)
                let age = now >= identity.modificationTimeUnixNs
                    ? now - identity.modificationTimeUnixNs
                    : 0
                guard priority || age <= configuration.recentFileAgeNs else { continue }
                byPath[canonical.canonicalPath] = Candidate(
                    path: canonical,
                    modificationTimeUnixNs: identity.modificationTimeUnixNs,
                    priority: priority
                )
                // Bound directory work independently from the selected result cap.
                if discoveredFileCount >= configuration.maximumFilesPerScan * 8 {
                    gaps.append(AgentDiscoveryGap(kind: .transcriptFileLimitReached))
                    break
                }
            }
        }
        return Array(byPath.values)
    }

    func consume(
        _ canonical: AgentCanonicalTranscriptPath,
        observedAt: UInt64
    ) -> (
        snapshot: AgentTranscriptSnapshot,
        readWasLimited: Bool,
        oversizedRecordWasSkipped: Bool
    )? {
        if canonical.provider == .cursor {
            return consumeCursor(canonical, observedAt: observedAt)
        }
        guard let identity = fileIdentity(at: canonical.canonicalPath) else { return nil }
        var state = states[canonical.canonicalPath]
        let replaced = state.map { $0.device != identity.device || $0.inode != identity.inode } ?? true
        let truncated = state.map { identity.size < $0.nextOffset } ?? false
        if state == nil || replaced || truncated {
            let start = identity.size > configuration.startupReplayBytes
                ? identity.size - configuration.startupReplayBytes
                : 0
            state = FileState(
                device: identity.device,
                inode: identity.inode,
                nextOffset: start,
                cwd: nil,
                role: canonical.provider == .claude ? .root : .unknown,
                latestUserPrompt: nil,
                latestAssistantText: nil,
                recentEvents: [],
                replayWasTruncated: start > 0,
                needsLeadingPartialDiscard: start > 0,
                isDiscardingOversizedRecord: false
            )
            if canonical.provider == .codex {
                primeCodexMetadata(canonical, state: &state!)
            }
        }
        guard var state else { return nil }

        if state.role == .internalSubagent {
            states[canonical.canonicalPath] = state
            let snapshot = AgentTranscriptSnapshot(
                provider: canonical.provider,
                providerSessionID: canonical.providerSessionID,
                role: state.role,
                path: canonical.canonicalPath,
                fileIdentity: identity,
                cwd: state.cwd,
                latestUserPrompt: nil,
                latestAssistantText: nil,
                recentEvents: [],
                nextReadOffset: state.nextOffset,
                replayWasTruncated: state.replayWasTruncated,
                observedAtUnixNs: observedAt
            )
            return (snapshot, false, false)
        }

        var oversizedRecordWasSkipped = state.isDiscardingOversizedRecord
        let readResult = readCompleteRecords(
            at: canonical.canonicalPath,
            from: state.nextOffset,
            expectedDevice: identity.device,
            expectedInode: identity.inode,
            discardLeadingPartial: state.needsLeadingPartialDiscard
        )
        state.needsLeadingPartialDiscard = readResult.needsLeadingPartialDiscard
        var recordLimitReached = false
        if let data = readResult.data {
            var cursor = 0
            var parsedRecords = 0
            while cursor < data.count,
                  parsedRecords < configuration.maximumRecordsPerFilePerScan,
                  let newline = data[cursor...].firstIndex(of: 0x0A)
            {
                let line = data[cursor ..< newline]
                let offset = readResult.dataStartOffset + UInt64(cursor)
                if !line.isEmpty,
                   let parsed = AgentTranscriptParser.parse(
                    Data(line),
                    provider: canonical.provider,
                    pathSessionID: canonical.providerSessionID,
                    sourceOffset: offset,
                    maximumTextCharacters: configuration.maximumTextCharacters
                   )
                {
                    if let cwd = parsed.cwd, !cwd.isEmpty {
                        state.cwd = Self.canonicalize(cwd)
                    }
                    if let role = parsed.role {
                        state.role = role
                    }
                    if let event = parsed.event {
                        switch event.kind {
                        case .userPrompt: state.latestUserPrompt = event
                        case .assistantText: state.latestAssistantText = event
                        case .sessionMetadata, .turnStarted, .turnCompleted, .turnAborted:
                            break
                        }
                        state.recentEvents.append(event)
                        if state.recentEvents.count > configuration.maximumRecentEventsPerTranscript {
                            state.recentEvents.removeFirst(
                                state.recentEvents.count - configuration.maximumRecentEventsPerTranscript
                            )
                        }
                    }
                }
                cursor = newline + 1
                parsedRecords += 1
            }
            recordLimitReached = parsedRecords >= configuration.maximumRecordsPerFilePerScan &&
                cursor < data.count
            let blockedAtBoundedRead = cursor == 0 &&
                parsedRecords == 0 &&
                !data.isEmpty &&
                readResult.wasLimited &&
                data.firstIndex(of: 0x0A) == nil
            if blockedAtBoundedRead {
                // One provider record can legitimately exceed the whole read budget
                // (for example, a base64 screenshot inside a tool result). Re-reading
                // that same prefix forever would pin lifecycle state before the record.
                // Skip this bounded chunk and discard through the record's newline on
                // later scans. Memory use remains capped and only the oversized record
                // is sacrificed; subsequent lifecycle records remain reachable.
                state.nextOffset = readResult.dataStartOffset + UInt64(data.count)
                state.needsLeadingPartialDiscard = true
                state.isDiscardingOversizedRecord = true
                oversizedRecordWasSkipped = true
            } else {
                state.nextOffset = readResult.dataStartOffset + UInt64(cursor)
            }
        } else {
            // While discarding an oversized record, a whole bounded chunk may contain
            // no newline. `dataStartOffset` is then the proven-safe continuation point.
            state.nextOffset = readResult.dataStartOffset
        }
        if !state.needsLeadingPartialDiscard {
            state.isDiscardingOversizedRecord = false
        }
        states[canonical.canonicalPath] = state

        let currentIdentity = AgentTranscriptFileIdentity(
            device: identity.device,
            inode: identity.inode,
            size: identity.size,
            modificationTimeUnixNs: identity.modificationTimeUnixNs
        )
        let snapshot = AgentTranscriptSnapshot(
            provider: canonical.provider,
            providerSessionID: canonical.providerSessionID,
            role: state.role,
            path: canonical.canonicalPath,
            fileIdentity: currentIdentity,
            cwd: state.cwd,
            latestUserPrompt: state.latestUserPrompt,
            latestAssistantText: state.latestAssistantText,
            recentEvents: state.recentEvents,
            nextReadOffset: state.nextOffset,
            replayWasTruncated: state.replayWasTruncated,
            observedAtUnixNs: observedAt
        )
        return (
            snapshot,
            readResult.wasLimited || recordLimitReached,
            oversizedRecordWasSkipped
        )
    }

    func consumeCursor(
        _ canonical: AgentCanonicalTranscriptPath,
        observedAt: UInt64
    ) -> (
        snapshot: AgentTranscriptSnapshot,
        readWasLimited: Bool,
        oversizedRecordWasSkipped: Bool
    )? {
        let previous = cursorStates[canonical.canonicalPath]?.cursor
        guard let result = try? cursorReader.read(
            storeURL: URL(fileURLWithPath: canonical.canonicalPath),
            cursor: previous,
            observedAtUnixNs: observedAt
        ), let diskIdentity = fileIdentity(at: canonical.canonicalPath)
        else { return nil }

        cursorStates[canonical.canonicalPath] = CursorState(cursor: result.cursor)
        let identity = AgentTranscriptFileIdentity(
            device: diskIdentity.device,
            inode: diskIdentity.inode,
            size: diskIdentity.size,
            modificationTimeUnixNs: result.combinedModificationTimeUnixNs
        )
        let latestHuman = result.latestHumanPrompt.map(Self.transcriptEvent)
        let latestAssistant = result.latestVisibleAssistantText.map(Self.transcriptEvent)

        // Cursor persists exact pending-tool state, but not its TUI's in-memory
        // `isGenerating` bit. Emit a working lifecycle event only for positive
        // activity evidence. Quiescent stores deliberately leave lifecycle unknown.
        var recentEvents: [AgentTranscriptEvent] = []
        if result.lifecycle != .quiescentUnknown {
            recentEvents.append(AgentTranscriptEvent(
                kind: .turnStarted,
                timestampUnixNs: result.cursor.lastActivityUnixNs,
                text: nil,
                sourceOffset: UInt64(max(0, result.cursor.maxRowID))
            ))
        }

        let activityState: AgentTranscriptActivityState = switch result.lifecycle {
        case .working: .working
        case .activeRecently: .activeRecently
        case .quiescentUnknown: .quiescentUnknown
        }
        let snapshot = AgentTranscriptSnapshot(
            provider: .cursor,
            providerSessionID: result.cursor.identity.agentID,
            role: .root,
            path: canonical.canonicalPath,
            fileIdentity: identity,
            cwd: cursorWorkingDirectory(beside: canonical.canonicalPath),
            latestUserPrompt: latestHuman,
            latestAssistantText: latestAssistant,
            recentEvents: recentEvents,
            nextReadOffset: UInt64(max(0, result.cursor.maxRowID)),
            replayWasTruncated: result.scanKind == .initialReverse &&
                result.cursor.orderedRootTurnBlobIDs.count >
                    cursorReader.configuration.maximumLatestLookupReferences,
            activityState: activityState,
            observedAtUnixNs: observedAt
        )
        return (snapshot, false, false)
    }

    private static func transcriptEvent(_ event: CursorAgentStoreEvent) -> AgentTranscriptEvent {
        AgentTranscriptEvent(
            kind: event.kind == .humanPrompt ? .userPrompt : .assistantText,
            timestampUnixNs: nil,
            text: event.text,
            sourceOffset: UInt64(max(0, event.rowID))
        )
    }

    private func cursorWorkingDirectory(beside storePath: String) -> String? {
        let metadataURL = URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("meta.json")
        // Cursor replaces this small file while an agent is running. A memory-mapped
        // Data can receive SIGBUS if the underlying inode is truncated between mapping
        // and JSON parsing. Read an owned, bounded snapshot through the descriptor so a
        // concurrent replacement yields either old bytes, new bytes, or a harmless
        // incomplete JSON document—never a process-fatal page fault.
        guard let snapshot = OwnedRegularFileReader.read(
            path: metadataURL.path,
            maximumBytes: (64 * 1_024) + 1
        ) else { return nil }
        let data = snapshot.data
        guard snapshot.fileSize <= 64 * 1_024,
              data.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = object["cwd"] as? String,
              !cwd.isEmpty
        else { return nil }
        return Self.canonicalize(cwd)
    }

    private func primeCodexMetadata(
        _ canonical: AgentCanonicalTranscriptPath,
        state: inout FileState
    ) {
        guard let snapshot = OwnedRegularFileReader.read(
            path: canonical.canonicalPath,
            maximumBytes: configuration.metadataPrefixBytes
        ), snapshot.device == state.device,
           snapshot.inode == state.inode
        else { return }
        let data = snapshot.data
        var cursor = 0
        while cursor < data.count,
              let newline = data[cursor...].firstIndex(of: 0x0A)
        {
            let line = data[cursor ..< newline]
            if let parsed = AgentTranscriptParser.parse(
                Data(line),
                provider: .codex,
                pathSessionID: canonical.providerSessionID,
                sourceOffset: UInt64(cursor),
                maximumTextCharacters: configuration.maximumTextCharacters
            ), parsed.role != nil {
                state.role = parsed.role ?? .unknown
                if let cwd = parsed.cwd { state.cwd = Self.canonicalize(cwd) }
                return
            }
            cursor = newline + 1
        }
    }

    private func readCompleteRecords(
        at path: String,
        from requestedOffset: UInt64,
        expectedDevice: UInt64,
        expectedInode: UInt64,
        discardLeadingPartial: Bool
    ) -> (
        data: Data?,
        dataStartOffset: UInt64,
        wasLimited: Bool,
        needsLeadingPartialDiscard: Bool
    ) {
        guard let snapshot = OwnedRegularFileReader.read(
            path: path,
            offset: requestedOffset,
            maximumBytes: configuration.maximumReadBytesPerFile
        ), snapshot.device == expectedDevice,
           snapshot.inode == expectedInode
        else {
            return (nil, requestedOffset, false, discardLeadingPartial)
        }
        let remaining = snapshot.fileSize - requestedOffset
        let limit = min(UInt64(configuration.maximumReadBytesPerFile), remaining)
        var data = snapshot.data
        var startOffset = requestedOffset
        if discardLeadingPartial,
           let firstNewline = data.firstIndex(of: 0x0A)
        {
            let discarded = firstNewline + 1
            // `Data.removeFirst` may preserve a non-zero startIndex. Re-materialize
            // the suffix so the bounded JSONL parser can use byte offsets from zero.
            data = Data(data.suffix(from: discarded))
            startOffset += UInt64(discarded)
        } else if discardLeadingPartial {
            let wasLimited = remaining > limit
            let continuation = wasLimited
                ? requestedOffset + UInt64(data.count)
                : requestedOffset
            return (nil, continuation, wasLimited, true)
        }
        return (data, startOffset, remaining > limit, false)
    }

    private func fileIdentity(at path: String) -> AgentTranscriptFileIdentity? {
        var value = Darwin.stat()
        guard lstat(path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        guard let modificationTimeUnixNs = Self.unixNanoseconds(value.st_mtimespec) else {
            return nil
        }
        return AgentTranscriptFileIdentity(
            device: UInt64(truncatingIfNeeded: value.st_dev),
            inode: UInt64(truncatingIfNeeded: value.st_ino),
            size: UInt64(max(0, value.st_size)),
            modificationTimeUnixNs: modificationTimeUnixNs
        )
    }

    private static func unixNanoseconds(_ value: timespec) -> UInt64? {
        guard value.tv_sec >= 0,
              value.tv_nsec >= 0,
              value.tv_nsec < 1_000_000_000
        else { return nil }
        let seconds = UInt64(value.tv_sec)
        let nanoseconds = UInt64(value.tv_nsec)
        let (base, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = base.addingReportingOverflow(nanoseconds)
        return multiplyOverflow || addOverflow ? nil : result
    }

    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
