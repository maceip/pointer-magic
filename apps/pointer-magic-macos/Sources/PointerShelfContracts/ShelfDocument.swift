import Foundation

public enum ShelfAccessoryKind: String, Codable, Hashable, Sendable {
    case expand
    case dismiss
}

public struct ShelfContextChip: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var dismissible: Bool

    public init(id: String, text: String, dismissible: Bool = true) {
        self.id = id
        self.text = Self.normalize(text)
        self.dismissible = dismissible
    }

    private static func normalize(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

public struct ShelfPromptSlot: Codable, Hashable, Sendable {
    public var placeholder: String

    public init(placeholder: String) {
        self.placeholder = Self.normalize(placeholder)
    }

    private static func normalize(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

public struct ShelfPrimaryCard: Codable, Hashable, Sendable {
    public var chips: [ShelfContextChip]
    public var prompt: ShelfPromptSlot?
    public var accessories: [ShelfAccessoryKind]

    public init(
        chips: [ShelfContextChip] = [],
        prompt: ShelfPromptSlot? = nil,
        accessories: [ShelfAccessoryKind] = [.dismiss]
    ) {
        self.chips = Array(chips.prefix(4))
        self.prompt = prompt
        self.accessories = accessories
    }
}

public enum ShelfActionIcon: Codable, Hashable, Sendable {
    case systemImage(String)
    case asset(String)

    public var systemImageName: String? {
        if case let .systemImage(name) = self { return name }
        return nil
    }
}

public struct ShelfActionPill: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var icon: ShelfActionIcon
    public var enabled: Bool
    public var rank: Int

    public init(
        id: String,
        title: String,
        icon: ShelfActionIcon,
        enabled: Bool = true,
        rank: Int = 0
    ) {
        self.id = id
        self.title = Self.normalize(title)
        self.icon = icon
        self.enabled = enabled
        self.rank = rank
    }

    private static func normalize(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Compact agent-style pill used when a provider does not supply a primary card.
public struct ShelfCompactFallback: Codable, Hashable, Sendable {
    public var provider: String
    public var providerMark: String
    public var directoryName: String
    public var state: String

    public init(
        provider: String,
        state: String,
        directoryName: String = "",
        providerMark: String = "unknown"
    ) {
        self.provider = Self.normalize(provider)
        self.providerMark = providerMark
        self.directoryName = Self.normalize(directoryName)
        self.state = Self.normalize(state)
    }

    public var isEmpty: Bool {
        provider.isEmpty && directoryName.isEmpty && state.isEmpty
    }

    private static func normalize(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Declarative shelf payload. Pointer Magic renders this; providers never draw.
public struct ShelfDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumVisibleActions = 5

    public var schemaVersion: Int
    public var id: String
    public var providerId: String
    public var revision: UInt64
    public var contextRevision: UInt64?
    public var ttlMs: UInt64
    public var primary: ShelfPrimaryCard?
    public var actions: [ShelfActionPill]
    public var fallback: ShelfCompactFallback?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        providerId: String,
        revision: UInt64,
        contextRevision: UInt64? = nil,
        ttlMs: UInt64 = 8_000,
        primary: ShelfPrimaryCard? = nil,
        actions: [ShelfActionPill] = [],
        fallback: ShelfCompactFallback? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.providerId = providerId
        self.revision = revision
        self.contextRevision = contextRevision
        self.ttlMs = ttlMs
        self.primary = primary
        self.actions = Array(
            actions
                .sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    return lhs.id < rhs.id
                }
                .prefix(Self.maximumVisibleActions)
        )
        self.fallback = fallback
    }

    public var isEmpty: Bool {
        primary == nil
            && actions.isEmpty
            && (fallback?.isEmpty ?? true)
    }

    public var usesExpandedLayout: Bool {
        primary != nil || !actions.isEmpty
    }

    /// Stable key for dismiss / reveal lease comparisons.
    public var dismissFingerprint: String {
        if let fallback, !fallback.isEmpty {
            return "compact:\(fallback.state)"
        }
        let chipText = primary?.chips.map(\.text).joined(separator: "|") ?? ""
        let actionIDs = actions.map(\.id).joined(separator: ",")
        return "expanded:\(chipText)#\(actionIDs)#\(revision)"
    }

    public static func compact(
        id: String,
        providerId: String,
        revision: UInt64,
        provider: String,
        state: String,
        directoryName: String = "",
        providerMark: String = "unknown",
        contextRevision: UInt64? = nil
    ) -> ShelfDocument {
        ShelfDocument(
            id: id,
            providerId: providerId,
            revision: revision,
            contextRevision: contextRevision,
            primary: nil,
            actions: [],
            fallback: ShelfCompactFallback(
                provider: provider,
                state: state,
                directoryName: directoryName,
                providerMark: providerMark
            )
        )
    }
}
