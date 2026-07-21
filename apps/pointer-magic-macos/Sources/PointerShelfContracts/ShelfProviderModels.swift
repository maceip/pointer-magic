import Foundation

public enum ShelfCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case focusTarget
    case readSelection
    case readThumb
    case pasteText
}

/// What a provider is interested in. The runtime filters before `propose`.
public struct ShelfProviderInterests: Codable, Hashable, Sendable {
    public var bundleIdentifierGlobs: [String]
    public var roles: [String]
    public var requiredCapabilities: [ShelfCapability]
    /// When true, the provider is asked for every packet (still subject to timeout).
    public var acceptsAnyContext: Bool

    public init(
        bundleIdentifierGlobs: [String] = [],
        roles: [String] = [],
        requiredCapabilities: [ShelfCapability] = [],
        acceptsAnyContext: Bool = false
    ) {
        self.bundleIdentifierGlobs = bundleIdentifierGlobs
        self.roles = roles
        self.requiredCapabilities = requiredCapabilities
        self.acceptsAnyContext = acceptsAnyContext
    }

    public static let any = ShelfProviderInterests(acceptsAnyContext: true)

    public func matches(_ packet: PointerContextPacket) -> Bool {
        if acceptsAnyContext { return true }

        if !bundleIdentifierGlobs.isEmpty {
            let bundle = packet.appWindow.bundleIdentifier ?? ""
            let bundleMatch = bundleIdentifierGlobs.contains { glob in
                Self.globMatches(glob, value: bundle)
            }
            if !bundleMatch { return false }
        }

        if !roles.isEmpty {
            let role = packet.hitTarget.role ?? ""
            if !roles.contains(where: { $0.caseInsensitiveCompare(role) == .orderedSame }) {
                return false
            }
        }

        return true
    }

    private static func globMatches(_ glob: String, value: String) -> Bool {
        if glob == "*" { return !value.isEmpty || true }
        if glob.hasSuffix(".*") {
            let prefix = String(glob.dropLast(2))
            return value == prefix || value.hasPrefix(prefix + ".")
        }
        if glob.hasSuffix("*") {
            let prefix = String(glob.dropLast())
            return value.hasPrefix(prefix)
        }
        return glob.caseInsensitiveCompare(value) == .orderedSame
    }
}

public enum ShelfProposal: Codable, Hashable, Sendable {
    case decline
    case document(ShelfDocument)

    public var document: ShelfDocument? {
        if case let .document(value) = self { return value }
        return nil
    }
}

public struct ShelfCapabilityGrant: Codable, Hashable, Sendable {
    public var capabilities: [ShelfCapability]
    public var contextRevision: UInt64
    public var documentRevision: UInt64
    public var actionId: String

    public init(
        capabilities: [ShelfCapability],
        contextRevision: UInt64,
        documentRevision: UInt64,
        actionId: String
    ) {
        self.capabilities = capabilities
        self.contextRevision = contextRevision
        self.documentRevision = documentRevision
        self.actionId = actionId
    }

    public func allows(_ capability: ShelfCapability) -> Bool {
        capabilities.contains(capability)
    }
}

public enum ShelfActionOutcome: String, Codable, Hashable, Sendable {
    case completed
    case denied
    case unavailable
    case failed
}

public struct ShelfActionResult: Codable, Hashable, Sendable {
    public var outcome: ShelfActionOutcome
    public var message: String

    public init(outcome: ShelfActionOutcome, message: String = "") {
        self.outcome = outcome
        self.message = message
    }

    public static func completed(_ message: String = "") -> ShelfActionResult {
        ShelfActionResult(outcome: .completed, message: message)
    }

    public static func denied(_ message: String) -> ShelfActionResult {
        ShelfActionResult(outcome: .denied, message: message)
    }

    public static func unavailable(_ message: String) -> ShelfActionResult {
        ShelfActionResult(outcome: .unavailable, message: message)
    }

    public static func failed(_ message: String) -> ShelfActionResult {
        ShelfActionResult(outcome: .failed, message: message)
    }
}

public struct ShelfInvokeRequest: Codable, Hashable, Sendable {
    public var actionId: String
    public var documentRevision: UInt64
    public var contextRevision: UInt64
    public var providerId: String

    public init(
        actionId: String,
        documentRevision: UInt64,
        contextRevision: UInt64,
        providerId: String
    ) {
        self.actionId = actionId
        self.documentRevision = documentRevision
        self.contextRevision = contextRevision
        self.providerId = providerId
    }
}
