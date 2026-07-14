import Foundation

/// The generation and lifetime shared by every active clutch state.
public struct PointerClutchLease: Codable, Hashable, Sendable {
    public let generation: UInt64
    public let expiresAtNs: UInt64

    public init(generation: UInt64, expiresAtNs: UInt64) {
        self.generation = generation
        self.expiresAtNs = expiresAtNs
    }

    public func isExpired(at nowNs: UInt64) -> Bool {
        nowNs >= expiresAtNs
    }
}

public enum PointerClutchState: Codable, Hashable, Sendable {
    case idle
    case following(PointerClutchLease)
    case pinning(PointerClutchLease)
    case latched(PointerClutchLease)

    public var lease: PointerClutchLease? {
        switch self {
        case .idle:
            nil
        case let .following(lease), let .pinning(lease), let .latched(lease):
            lease
        }
    }
}

public enum PointerClutchEvent: Codable, Hashable, Sendable {
    case beginFollowing(lease: PointerClutchLease, nowNs: UInt64)
    case optionDown(nowNs: UInt64)
    case pointerEnteredPanel(nowNs: UInt64)
    case optionUp(nowNs: UInt64)
    case resumeFollowingFromPanel(nowNs: UInt64)
    case escape
    case expiry(nowNs: UInt64)

    fileprivate var nowNs: UInt64? {
        switch self {
        case let .beginFollowing(_, nowNs),
             let .optionDown(nowNs),
             let .pointerEnteredPanel(nowNs),
             let .optionUp(nowNs),
             let .resumeFollowingFromPanel(nowNs),
             let .expiry(nowNs):
            nowNs
        case .escape:
            nil
        }
    }
}

public enum PointerClutchReducer {
    /// Returns the next clutch state without reading clocks, modifiers, or UI objects.
    public static func reduce(
        state: PointerClutchState,
        event: PointerClutchEvent
    ) -> PointerClutchState {
        if case let .beginFollowing(lease, nowNs) = event {
            return lease.isExpired(at: nowNs) ? .idle : .following(lease)
        }

        if case .escape = event {
            return .idle
        }

        if let lease = state.lease,
           let nowNs = event.nowNs,
           lease.isExpired(at: nowNs)
        {
            return .idle
        }

        return switch (state, event) {
        case let (.following(lease), .optionDown):
            .pinning(lease)

        case let (.pinning(lease), .pointerEnteredPanel):
            .latched(lease)

        case let (.pinning(lease), .optionUp):
            .following(lease)

        case (.latched, .optionUp):
            state

        case let (.latched(lease), .resumeFollowingFromPanel):
            .following(lease)

        case (_, .expiry):
            state

        default:
            state
        }
    }
}
