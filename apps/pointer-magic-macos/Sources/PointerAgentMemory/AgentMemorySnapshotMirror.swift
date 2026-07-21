import Foundation
import PointerAgentContracts

/// Small publication cell for immutable snapshots. The lock protects only one
/// value copy; readers perform filtering and presentation after it is released.
private final class PublishedAgentShelfSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: AgentShelfSnapshot = .empty
    private var publicationCount: UInt64 = 0

    func load() -> AgentShelfSnapshot {
        lock.lock()
        let result = snapshot
        lock.unlock()
        return result
    }

    func count() -> UInt64 {
        lock.lock()
        let result = publicationCount
        lock.unlock()
        return result
    }

    @discardableResult
    func publishIfNewer(_ candidate: AgentShelfSnapshot) -> Bool {
        lock.lock()
        guard candidate.revision > snapshot.revision else {
            lock.unlock()
            return false
        }
        // Release a potentially large displaced snapshot outside the reader lock.
        let displaced = snapshot
        snapshot = candidate
        if publicationCount < UInt64.max { publicationCount += 1 }
        lock.unlock()
        withExtendedLifetime(displaced) {}
        return true
    }
}

/// Ingestion facade plus a synchronous, cache-only snapshot read. The actor store
/// remains the sole reducer; `cachedSnapshot()` never awaits, performs I/O, inspects
/// a process, or creates authority for an action.
public final class AgentMemorySnapshotMirror: AgentObservationSink, @unchecked Sendable {
    public let store: AgentMemoryStore
    private let published = PublishedAgentShelfSnapshot()

    public init(store: AgentMemoryStore) {
        self.store = store
    }

    public func ingest(_ batch: AgentObservationBatch) async -> AgentIngestReceipt {
        let receipt = await store.ingest(batch)
        switch receipt.status {
        case .accepted, .acceptedWithAmbiguity:
            let snapshot = await store.shelfSnapshot()
            published.publishIfNewer(snapshot)
        case .replayed, .rejected:
            break
        }
        return receipt
    }

    /// Publishes actor-side changes not made by observation ingestion, including an
    /// explicit human attention selection.
    @discardableResult
    public func synchronizeSnapshot() async -> Bool {
        let snapshot = await store.shelfSnapshot()
        return published.publishIfNewer(snapshot)
    }

    public func selectAttention(
        _ target: AgentHumanAttentionTarget
    ) async -> AgentAttentionSelectionResult {
        let result = await store.selectAttention(target)
        if case .selected = result {
            _ = await synchronizeSnapshot()
        }
        return result
    }

    /// Nonisolated, bounded read of the latest published immutable value.
    public func cachedSnapshot() -> AgentShelfSnapshot {
        published.load()
    }

    public var publishedRevision: AgentMemoryRevision {
        published.load().revision
    }

    public var snapshotPublicationCount: UInt64 {
        published.count()
    }
}
