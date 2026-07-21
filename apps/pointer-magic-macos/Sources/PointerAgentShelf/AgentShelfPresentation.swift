import Foundation
import PointerShelfContracts

/// Separates a user-relevant item transition from passive observer churn.
/// Passive updates may refresh the value behind the shelf, but cannot reopen it
/// or extend the five-second reveal lease.
public enum AgentShelfUpdateSignificance: Hashable, Sendable {
    case passive
    case meaningful
}

public enum AgentShelfProviderMark: String, Codable, Hashable, Sendable {
    case codex
    case cursor
    case claude
    case geminiAntigravity
    case unknown

    public init(providerName: String) {
        let normalized = providerName
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized.contains("codex") || normalized == "openai" {
            self = .codex
        } else if normalized.contains("cursor") {
            self = .cursor
        } else if normalized.contains("claude") || normalized.contains("anthropic") {
            self = .claude
        } else if normalized.contains("gemini") || normalized.contains("antigravity") {
            self = .geminiAntigravity
        } else {
            self = .unknown
        }
    }
}

/// Display-ready shelf payload. Contains no observer or provider-runtime types.
public struct AgentShelfPresentation: Hashable, Sendable {
    public let provider: String
    public let providerMark: AgentShelfProviderMark
    public let directoryName: String
    public let state: String

    public init(
        provider: String,
        state: String,
        directoryName: String = "",
        providerMark: AgentShelfProviderMark? = nil
    ) {
        self.provider = Self.normalize(provider)
        self.providerMark = providerMark ?? AgentShelfProviderMark(providerName: provider)
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

    public func asShelfDocument(
        id: String,
        revision: UInt64 = 1,
        contextRevision: UInt64? = nil
    ) -> ShelfDocument {
        ShelfDocument.compact(
            id: id,
            providerId: AgentShelfPresentation.agentProviderID,
            revision: revision,
            provider: provider,
            state: state,
            directoryName: directoryName,
            providerMark: providerMark.rawValue,
            contextRevision: contextRevision
        )
    }

    public static let agentProviderID = "agent"

    public init?(compact fallback: ShelfCompactFallback) {
        guard !fallback.isEmpty else { return nil }
        self.init(
            provider: fallback.provider,
            state: fallback.state,
            directoryName: fallback.directoryName,
            providerMark: AgentShelfProviderMark(rawValue: fallback.providerMark)
                ?? AgentShelfProviderMark(providerName: fallback.provider)
        )
    }
}
