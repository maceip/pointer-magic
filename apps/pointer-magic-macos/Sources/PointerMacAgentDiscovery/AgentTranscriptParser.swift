import Foundation

public struct AgentCanonicalTranscriptPath: Hashable, Sendable {
    public let provider: AgentProvider
    public let canonicalPath: String
    public let providerSessionID: String

    public init(provider: AgentProvider, canonicalPath: String, providerSessionID: String) {
        self.provider = provider
        self.canonicalPath = canonicalPath
        self.providerSessionID = providerSessionID
    }

    /// Accepts only provider-owned main transcript layouts. Claude `subagents/`
    /// descendants and arbitrary JSONL/SQLite files elsewhere are rejected before
    /// parsing. Cursor's WAL/SHM paths normalize to the identity-bearing store DB.
    public static func classify(_ path: String) -> AgentCanonicalTranscriptPath? {
        let canonical = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let codexRoot = home + "/.codex/sessions/"
        if canonical.hasPrefix(codexRoot) {
            let relative = String(canonical.dropFirst(codexRoot.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 4,
                  components[0].count == 4,
                  components[1].count == 2,
                  components[2].count == 2,
                  let sessionID = uuid(inJSONLName: String(components[3]))
            else { return nil }
            return AgentCanonicalTranscriptPath(
                provider: .codex,
                canonicalPath: canonical,
                providerSessionID: sessionID
            )
        }

        let claudeRoot = home + "/.claude/projects/"
        if canonical.hasPrefix(claudeRoot) {
            let relative = String(canonical.dropFirst(claudeRoot.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 2,
                  let sessionID = exactUUIDJSONLName(String(components[1]))
            else { return nil }
            return AgentCanonicalTranscriptPath(
                provider: .claude,
                canonicalPath: canonical,
                providerSessionID: sessionID
            )
        }

        let cursorRoot = home + "/.cursor/chats/"
        if canonical.hasPrefix(cursorRoot) {
            let storePath: String
            if canonical.hasSuffix("/store.db-wal") {
                storePath = String(canonical.dropLast(4))
            } else if canonical.hasSuffix("/store.db-shm") {
                storePath = String(canonical.dropLast(4))
            } else {
                storePath = canonical
            }
            let relative = String(storePath.dropFirst(cursorRoot.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 3,
                  isLowercaseHex(String(components[0]), count: 32),
                  UUID(uuidString: String(components[1])) != nil,
                  components[2] == "store.db"
            else { return nil }
            return AgentCanonicalTranscriptPath(
                provider: .cursor,
                canonicalPath: storePath,
                providerSessionID: String(components[1]).lowercased()
            )
        }
        return nil
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(String(character))
        }
    }

    private static func exactUUIDJSONLName(_ name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        guard UUID(uuidString: stem) != nil else { return nil }
        return stem.lowercased()
    }

    private static func uuid(inJSONLName name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        guard let range = stem.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) else { return nil }
        let value = String(stem[range])
        guard UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
}

struct ParsedAgentTranscriptLine: Sendable {
    let sessionID: String?
    let cwd: String?
    let role: AgentTranscriptRole?
    let event: AgentTranscriptEvent?
}

enum AgentTranscriptParser {
    static func parse(
        _ data: Data,
        provider: AgentProvider,
        pathSessionID: String,
        sourceOffset: UInt64,
        maximumTextCharacters: Int
    ) -> ParsedAgentTranscriptLine? {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return nil }
        switch provider {
        case .codex:
            return parseCodex(
                object,
                pathSessionID: pathSessionID,
                sourceOffset: sourceOffset,
                maximumTextCharacters: maximumTextCharacters
            )
        case .claude:
            return parseClaude(
                object,
                pathSessionID: pathSessionID,
                sourceOffset: sourceOffset,
                maximumTextCharacters: maximumTextCharacters
            )
        case .cursor:
            // Cursor CLI uses its provider-owned SQLite store, not JSONL records.
            return nil
        }
    }

    private static func parseCodex(
        _ object: [String: Any],
        pathSessionID: String,
        sourceOffset: UInt64,
        maximumTextCharacters: Int
    ) -> ParsedAgentTranscriptLine? {
        let timestamp = timestampNs(object["timestamp"])
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]

        if type == "session_meta" {
            let cwd = payload["cwd"] as? String
            let role = codexRole(from: payload["source"])
            return ParsedAgentTranscriptLine(
                sessionID: pathSessionID,
                cwd: cwd,
                role: role,
                event: AgentTranscriptEvent(
                    kind: .sessionMetadata,
                    timestampUnixNs: timestamp,
                    text: nil,
                    sourceOffset: sourceOffset
                )
            )
        }

        if type == "turn_context", let cwd = payload["cwd"] as? String {
            return ParsedAgentTranscriptLine(
                sessionID: pathSessionID,
                cwd: cwd,
                role: nil,
                event: nil
            )
        }

        if type == "event_msg", let inner = payload["type"] as? String {
            let lifecycleKind: AgentTranscriptEventKind? = switch inner {
            case "task_started": .turnStarted
            case "task_complete": .turnCompleted
            case "turn_aborted": .turnAborted
            default: nil
            }
            if let lifecycleKind {
                return ParsedAgentTranscriptLine(
                    sessionID: pathSessionID,
                    cwd: nil,
                    role: nil,
                    event: AgentTranscriptEvent(
                        kind: lifecycleKind,
                        timestampUnixNs: timestamp,
                        text: nil,
                        sourceOffset: sourceOffset
                    )
                )
            }
            let kind: AgentTranscriptEventKind?
            switch inner {
            case "user_message": kind = .userPrompt
            case "agent_message": kind = .assistantText
            default: kind = nil
            }
            guard let kind else { return nil }
            let text = extractText(payload, maximum: maximumTextCharacters)
            let imageAttachments = codexLocalImageAttachments(
                payload,
                sourceOffset: sourceOffset
            )
            guard text != nil || !imageAttachments.isEmpty,
                  kind != .userPrompt || text.map(isSyntheticCodexPrompt) != true
            else { return nil }
            return ParsedAgentTranscriptLine(
                sessionID: pathSessionID,
                cwd: nil,
                role: nil,
                event: AgentTranscriptEvent(
                    kind: kind,
                    timestampUnixNs: timestamp,
                    text: text,
                    imageAttachments: imageAttachments,
                    sourceOffset: sourceOffset
                )
            )
        }

        return nil
    }

    private static func parseClaude(
        _ object: [String: Any],
        pathSessionID: String,
        sourceOffset: UInt64,
        maximumTextCharacters: Int
    ) -> ParsedAgentTranscriptLine? {
        let recordSessionID = object["sessionId"] as? String
        if let recordSessionID,
           recordSessionID.caseInsensitiveCompare(pathSessionID) != .orderedSame
        {
            return nil
        }
        let sessionID = recordSessionID ?? pathSessionID
        let cwd = object["cwd"] as? String
        let timestamp = timestampNs(object["timestamp"])
        let type = object["type"] as? String
        let isSidechain = object["isSidechain"] as? Bool ?? false
        guard !isSidechain else {
            return ParsedAgentTranscriptLine(
                sessionID: sessionID,
                cwd: cwd,
                role: nil,
                event: nil
            )
        }

        if type == "system", object["subtype"] as? String == "turn_duration" {
            return ParsedAgentTranscriptLine(
                sessionID: sessionID,
                cwd: cwd,
                role: .root,
                event: AgentTranscriptEvent(
                    kind: .turnCompleted,
                    timestampUnixNs: timestamp,
                    text: nil,
                    sourceOffset: sourceOffset
                )
            )
        }

        if type == "user" {
            // A genuine operator turn is intentionally strict. Tool results and
            // synthesized side-chain messages also use type=user in Claude logs.
            let origin = object["origin"] as? [String: Any]
            let originKind = origin?["kind"] as? String
            let promptSource = object["promptSource"] as? String
            let entrypoint = object["entrypoint"] as? String
            let originAllowsHuman = originKind == nil || originKind == "human"
            let sourceAllowsHuman = promptSource == "typed" || promptSource == "queued"
            guard originAllowsHuman, sourceAllowsHuman, entrypoint == "cli",
                  let message = object["message"] as? [String: Any],
                  let rawText = message["content"] as? String,
                  let text = boundedNonempty(rawText, maximum: maximumTextCharacters)
            else {
                return ParsedAgentTranscriptLine(
                    sessionID: sessionID,
                    cwd: cwd,
                    role: .root,
                    event: nil
                )
            }
            return ParsedAgentTranscriptLine(
                sessionID: sessionID,
                cwd: cwd,
                role: .root,
                event: AgentTranscriptEvent(
                    kind: .userPrompt,
                    timestampUnixNs: timestamp,
                    text: text,
                    sourceOffset: sourceOffset
                )
            )
        }

        if type == "assistant",
           let message = object["message"] as? [String: Any],
           let text = extractMessageContent(
            message["content"],
            maximum: maximumTextCharacters
           )
        {
            return ParsedAgentTranscriptLine(
                sessionID: sessionID,
                cwd: cwd,
                role: .root,
                event: AgentTranscriptEvent(
                    kind: .assistantText,
                    timestampUnixNs: timestamp,
                    text: text,
                    sourceOffset: sourceOffset
                )
            )
        }

        // Metadata-bearing records still establish that this canonical file is a
        // root session without treating internal/system content as human attention.
        guard recordSessionID != nil || cwd != nil else { return nil }
        return ParsedAgentTranscriptLine(
            sessionID: sessionID,
            cwd: cwd,
            role: .root,
            event: nil
        )
    }

    private static func codexRole(from source: Any?) -> AgentTranscriptRole {
        guard let source else { return .root }
        if let source = source as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let spawn = subagent["thread_spawn"],
           !(spawn is NSNull)
        {
            return .internalSubagent
        }
        return .root
    }

    private static func extractText(
        _ object: [String: Any],
        maximum: Int
    ) -> String? {
        for key in ["message", "text", "content"] {
            if let text = object[key] as? String {
                return boundedNonempty(text, maximum: maximum)
            }
            if let text = extractMessageContent(object[key], maximum: maximum) {
                return text
            }
        }
        return nil
    }

    private static func extractMessageContent(_ value: Any?, maximum: Int) -> String? {
        if let string = value as? String {
            return boundedNonempty(string, maximum: maximum)
        }
        guard let parts = value as? [Any] else { return nil }
        var output: [String] = []
        var remaining = maximum
        for case let part as [String: Any] in parts where remaining > 0 {
            let type = part["type"] as? String
            guard type == nil || ["text", "input_text", "output_text"].contains(type!) else {
                continue
            }
            guard let text = part["text"] as? String else { continue }
            let clipped = bounded(text, maximum: remaining)
            guard !clipped.isEmpty else { continue }
            output.append(clipped)
            remaining -= clipped.count
        }
        let joined = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func codexLocalImageAttachments(
        _ payload: [String: Any],
        sourceOffset: UInt64
    ) -> [AgentTranscriptImageAttachment] {
        guard let paths = payload["local_images"] as? [Any] else { return [] }
        return paths.prefix(8).enumerated().compactMap { index, value in
            guard let rawPath = value as? String,
                  rawPath.utf8.count <= 4_096,
                  (rawPath as NSString).isAbsolutePath
            else { return nil }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return AgentTranscriptImageAttachment(
                identifier: "\(sourceOffset):\(index)",
                localFilePath: path
            )
        }
    }

    private static func bounded(_ text: String, maximum: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximum else { return trimmed }
        return String(trimmed.prefix(maximum))
    }

    private static func boundedNonempty(_ text: String, maximum: Int) -> String? {
        let result = bounded(text, maximum: maximum)
        return result.isEmpty ? nil : result
    }

    private static func isSyntheticCodexPrompt(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("<environment_context>") ||
            normalized.hasPrefix("<permissions instructions>") ||
            normalized.hasPrefix("<collaboration_mode>") ||
            normalized.hasPrefix("<skills_instructions>")
    }

    private static func timestampNs(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite, raw >= 0 else { return nil }
            let nanoseconds: Double
            if raw > 1e18 {
                nanoseconds = raw
            } else if raw > 1e15 {
                nanoseconds = raw * 1_000
            } else if raw > 1e12 {
                nanoseconds = raw * 1_000_000
            } else {
                nanoseconds = raw * 1_000_000_000
            }
            return boundedTimestampNanoseconds(nanoseconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: string) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }()
        guard let date else { return nil }
        return boundedTimestampNanoseconds(
            date.timeIntervalSince1970 * 1_000_000_000
        )
    }

    /// Swift's floating-point integer conversion traps when the value is outside the
    /// destination range. Transcript timestamps are external data, so reject them before
    /// conversion instead of allowing one malformed line to terminate the process.
    private static func boundedTimestampNanoseconds(_ value: Double) -> UInt64? {
        guard value.isFinite,
              value >= 0,
              value < Double(UInt64.max)
        else { return nil }
        return UInt64(value)
    }
}
