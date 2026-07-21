import Foundation

public struct MacAgentDiscoveryControllerConfiguration: Hashable, Sendable {
    public let pollingIntervalNs: UInt64
    public let filesystemEventCoalescingNs: UInt64
    public let maximumTranscriptFileWatches: Int

    public init(
        pollingIntervalNs: UInt64 = 2_000_000_000,
        filesystemEventCoalescingNs: UInt64 = 35_000_000,
        maximumTranscriptFileWatches: Int = 256
    ) {
        self.pollingIntervalNs = max(250_000_000, pollingIntervalNs)
        self.filesystemEventCoalescingNs = max(
            5_000_000,
            min(filesystemEventCoalescingNs, 250_000_000)
        )
        self.maximumTranscriptFileWatches = max(
            1,
            min(maximumTranscriptFileWatches, 1_024)
        )
    }

    public static let `default` = MacAgentDiscoveryControllerConfiguration()
}

/// Owns the passive observation loop. Discovery has no dependency on pointer events,
/// UI, terminal wrappers, PTYs, input injection, AppleScript, or network transport.
public actor MacAgentDiscoveryController {
    public let configuration: MacAgentDiscoveryControllerConfiguration
    public let processCensus: MacProcessCensus
    public let transcriptRegistry: AgentTranscriptRegistry

    private var revision: UInt64 = 0
    private var latest: MacAgentDiscoverySnapshot = .empty
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<MacAgentDiscoverySnapshot, Never>?
    private var refreshToken: UUID?
    private var lastProcessResult: MacProcessCensusResult?
    private var activeTranscriptWakePaths: Set<String> = []
    private let transcriptFileWatches = AgentTranscriptFileWatchSet()
    private var filesystemRefreshTask: Task<Void, Never>?
    private var filesystemChangePending = false
    private var isStarted = false
    private var continuations: [UUID: AsyncStream<MacAgentDiscoverySnapshot>.Continuation] = [:]

    public init(
        configuration: MacAgentDiscoveryControllerConfiguration = .default,
        processCensus: MacProcessCensus = MacProcessCensus(),
        transcriptRegistry: AgentTranscriptRegistry = AgentTranscriptRegistry()
    ) {
        self.configuration = configuration
        self.processCensus = processCensus
        self.transcriptRegistry = transcriptRegistry
    }

    public func start() {
        guard pollingTask == nil else { return }
        isStarted = true
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.refresh()
                do {
                    try await Task.sleep(nanoseconds: self.configuration.pollingIntervalNs)
                } catch {
                    break
                }
            }
        }
    }

    public func stop() async {
        isStarted = false
        pollingTask?.cancel()
        pollingTask = nil
        filesystemRefreshTask?.cancel()
        filesystemRefreshTask = nil
        filesystemChangePending = false
        activeTranscriptWakePaths.removeAll(keepingCapacity: false)
        await transcriptFileWatches.stop()
        if let refreshTask, let refreshToken {
            _ = await refreshTask.value
            if self.refreshToken == refreshToken {
                self.refreshTask = nil
                self.refreshToken = nil
            }
        }
    }

    public func snapshot() -> MacAgentDiscoverySnapshot { latest }

    /// Filesystem adapters may call this as an early hint. Correctness never depends
    /// on delivery of a filesystem event; the bounded poll still reconciles.
    @discardableResult
    public func filesystemDidChange() async -> MacAgentDiscoverySnapshot {
        await refresh()
    }

    @discardableResult
    public func refresh() async -> MacAgentDiscoverySnapshot {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { [weak self] in
            guard let self else { return MacAgentDiscoverySnapshot.empty }
            return await self.performRefresh()
        }
        let token = UUID()
        refreshTask = task
        refreshToken = token
        let result = await task.value
        if refreshToken == token {
            refreshTask = nil
            refreshToken = nil
        }
        return result
    }

    private func performRefresh() async -> MacAgentDiscoverySnapshot {
        let census = processCensus
        let processResult = await Task.detached(priority: .utility) {
            census.scan()
        }.value
        lastProcessResult = processResult
        let priorityPaths = Set(processResult.processes.flatMap(\.openTranscriptPaths))
        let wakePaths = Set(processResult.processes.flatMap(\.transcriptWakePaths))
        activeTranscriptWakePaths = wakePaths
        if isStarted {
            await transcriptFileWatches.reconcilePaths(
                wakePaths,
                maximumCount: configuration.maximumTranscriptFileWatches
            ) { [weak self] path in
                Task {
                    await self?.watchedTranscriptDidChange(path)
                }
            }
            // `stop()` can run while reconciliation is suspended on the watch actor.
            // Never let that race recreate descriptors after shutdown.
            if !isStarted {
                await transcriptFileWatches.stop()
            }
        } else {
            await transcriptFileWatches.stop()
        }
        let transcriptResult = await transcriptRegistry.scan(priorityPaths: priorityPaths)
        return publish(processResult: processResult, transcriptResult: transcriptResult)
    }

    /// Vnode writes use the last authoritative process census and touch only the
    /// small set of exact open provider stores. The periodic full census remains the
    /// liveness/coverage authority, but it is not on the typing-to-shelf latency path.
    private func performTranscriptOnlyRefresh() async -> MacAgentDiscoverySnapshot {
        guard let processResult = lastProcessResult else {
            return await performRefresh()
        }
        let priorityPaths = Set(processResult.processes.flatMap(\.openTranscriptPaths))
        let transcriptResult = await transcriptRegistry.scan(priorityPaths: priorityPaths)
        return publish(processResult: processResult, transcriptResult: transcriptResult)
    }

    private func publish(
        processResult: MacProcessCensusResult,
        transcriptResult: AgentTranscriptRegistryResult
    ) -> MacAgentDiscoverySnapshot {
        let sessions = AgentSessionCorrelator.correlate(
            processes: processResult.processes,
            transcripts: transcriptResult.transcripts
        )
        revision = revision == UInt64.max ? UInt64.max : revision + 1
        latest = MacAgentDiscoverySnapshot(
            revision: revision,
            observedAtUnixNs: agentUnixTimeNs(),
            processes: processResult.processes,
            transcripts: transcriptResult.transcripts,
            sessions: sessions,
            gaps: processResult.gaps + transcriptResult.gaps
        )
        for continuation in continuations.values {
            continuation.yield(latest)
        }
        return latest
    }

    public func updates() -> AsyncStream<MacAgentDiscoverySnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(latest)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func watchedTranscriptDidChange(_ path: String) {
        guard isStarted, activeTranscriptWakePaths.contains(path) else { return }
        filesystemChangePending = true
        guard filesystemRefreshTask == nil else { return }
        filesystemRefreshTask = Task { [weak self] in
            await self?.drainFilesystemChanges()
        }
    }

    private func drainFilesystemChanges() async {
        while isStarted, filesystemChangePending, !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: configuration.filesystemEventCoalescingNs
                )
            } catch {
                break
            }
            guard isStarted, !Task.isCancelled else { break }

            // Everything delivered during the short debounce is represented by this
            // refresh. A write arriving while the refresh is suspended sets the flag
            // again and receives one trailing refresh rather than being lost.
            filesystemChangePending = false
            _ = await refreshAfterCurrentWork()
        }
        filesystemRefreshTask = nil

        // There is no suspension between the loop condition and clearing the task, so
        // a later event will either be seen above or create a fresh drain task itself.
        if isStarted, filesystemChangePending {
            filesystemRefreshTask = Task { [weak self] in
                await self?.drainFilesystemChanges()
            }
        }
    }

    private func refreshAfterCurrentWork() async -> MacAgentDiscoverySnapshot {
        // Joining an older in-flight scan is insufficient: its transcript read may
        // already have happened before this vnode event. Drain it, clear its token if
        // necessary, and then begin one refresh known to start after the write hint.
        if let activeTask = refreshTask, let activeToken = refreshToken {
            _ = await activeTask.value
            if refreshToken == activeToken {
                refreshTask = nil
                refreshToken = nil
            }
        }
        guard isStarted, !Task.isCancelled else { return latest }
        return await refreshTranscripts()
    }

    private func refreshTranscripts() async -> MacAgentDiscoverySnapshot {
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { [weak self] in
            guard let self else { return MacAgentDiscoverySnapshot.empty }
            return await self.performTranscriptOnlyRefresh()
        }
        let token = UUID()
        refreshTask = task
        refreshToken = token
        let result = await task.value
        if refreshToken == token {
            refreshTask = nil
            refreshToken = nil
        }
        return result
    }
}
