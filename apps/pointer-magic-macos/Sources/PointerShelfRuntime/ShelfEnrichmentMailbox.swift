import Foundation
import PointerShelfContracts

/// Latest-wins enrichment fence. Same idea as a game present loop: bump generation
/// to supersede in-flight work; only the current generation may commit.
public struct ShelfEnrichmentMailbox: Sendable, Equatable {
    public private(set) var generation: UInt64

    public init(generation: UInt64 = 0) {
        self.generation = generation
    }

    /// Starts a new enrichment attempt and invalidates every prior candidate.
    @discardableResult
    public mutating func beginAttempt() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ attempt: UInt64) -> Bool {
        attempt == generation
    }

    /// Returns the document only when the attempt still owns the mailbox.
    public func commitIfCurrent(
        attempt: UInt64,
        document: ShelfDocument
    ) -> ShelfDocument? {
        guard isCurrent(attempt), !document.isEmpty else { return nil }
        return document
    }
}
