import Foundation

public enum SceneTokenOfferResult: Equatable, Sendable {
    case inserted
    case coalesced
    case overflowed
    case closed
}

public struct SceneTokenMailboxDrain<Token: Hashable & Sendable>: Sendable {
    public let tokens: [Token]
    /// Once true, consumers must publish a coverage gap before treating a later
    /// checkpoint as current. The token that exceeded capacity is intentionally lost.
    public let overflowed: Bool

    public init(tokens: [Token], overflowed: Bool) {
        self.tokens = tokens
        self.overflowed = overflowed
    }
}

public enum SceneTokenMailboxWaitResult<Token: Hashable & Sendable>: Sendable {
    case drained(SceneTokenMailboxDrain<Token>)
    case closed
}

/// A synchronous callback-safe mailbox. Producers perform no allocation after a token
/// has already been coalesced. It is intentionally lock based so OS callbacks can offer
/// work without creating Tasks or crossing an actor boundary.
public final class BoundedSceneTokenMailbox<Token: Hashable & Sendable>: @unchecked Sendable {
    public let capacity: Int

    private let condition = NSCondition()
    private var orderedTokens: [Token] = []
    private var tokenSet: Set<Token> = []
    private var overflowed = false
    private var isClosed = false

    public init(capacity: Int) {
        precondition(capacity > 0, "Mailbox capacity must be positive")
        self.capacity = capacity
        orderedTokens.reserveCapacity(capacity)
        tokenSet.reserveCapacity(capacity)
    }

    @discardableResult
    public func offer(_ token: Token) -> SceneTokenOfferResult {
        condition.lock()
        defer { condition.unlock() }

        guard !isClosed else { return .closed }
        if tokenSet.contains(token) { return .coalesced }
        guard orderedTokens.count < capacity else {
            overflowed = true
            condition.signal()
            return .overflowed
        }

        orderedTokens.append(token)
        tokenSet.insert(token)
        condition.signal()
        return .inserted
    }

    /// Nonblocking drain for deterministic tests and callers that already have a wakeup.
    public func drain() -> SceneTokenMailboxDrain<Token>? {
        condition.lock()
        defer { condition.unlock() }
        guard !orderedTokens.isEmpty || overflowed else { return nil }
        return takeLocked()
    }

    /// Blocks a dedicated utility worker until work arrives or the mailbox closes.
    public func waitAndDrain() -> SceneTokenMailboxWaitResult<Token> {
        condition.lock()
        defer { condition.unlock() }
        while orderedTokens.isEmpty, !overflowed, !isClosed {
            condition.wait()
        }
        guard !isClosed else { return .closed }
        return .drained(takeLocked())
    }

    public func close() {
        condition.lock()
        isClosed = true
        orderedTokens.removeAll(keepingCapacity: false)
        tokenSet.removeAll(keepingCapacity: false)
        overflowed = false
        condition.broadcast()
        condition.unlock()
    }

    private func takeLocked() -> SceneTokenMailboxDrain<Token> {
        let result = SceneTokenMailboxDrain(tokens: orderedTokens, overflowed: overflowed)
        orderedTokens.removeAll(keepingCapacity: true)
        tokenSet.removeAll(keepingCapacity: true)
        overflowed = false
        return result
    }
}
