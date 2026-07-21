import Foundation

/// Opaque identity for one shelf item. Providers mint these; the shelf runtime
/// never interprets the payload as an agent, window, or process type.
public struct ShelfItemIdentity: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Dismissal is keyed by identity plus the rendered state string so a response-only
/// refresh cannot resurrect the same update the person just hid.
public struct ShelfDismissKey: Hashable, Sendable {
    public let identity: ShelfItemIdentity
    public let state: String

    public init(identity: ShelfItemIdentity, state: String) {
        self.identity = identity
        self.state = state
    }
}
