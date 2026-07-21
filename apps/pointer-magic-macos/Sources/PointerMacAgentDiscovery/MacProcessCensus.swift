import Foundation
import PointerC

public struct MacProcessCensusConfiguration: Hashable, Sendable {
    public let maximumListedProcesses: Int
    public let maximumAgentCandidates: Int
    public let maximumArgumentBytes: Int
    public let maximumOpenFileBytes: Int
    public let maximumOpenFilePaths: Int

    public init(
        maximumListedProcesses: Int = 4_096,
        maximumAgentCandidates: Int = 128,
        maximumArgumentBytes: Int = 128 * 1_024,
        maximumOpenFileBytes: Int = 512 * 1_024,
        maximumOpenFilePaths: Int = 1_024
    ) {
        self.maximumListedProcesses = max(1, min(maximumListedProcesses, 16_384))
        self.maximumAgentCandidates = max(1, min(maximumAgentCandidates, 1_024))
        self.maximumArgumentBytes = max(4_096, min(maximumArgumentBytes, 1_024 * 1_024))
        self.maximumOpenFileBytes = max(16_384, min(maximumOpenFileBytes, 4 * 1_024 * 1_024))
        self.maximumOpenFilePaths = max(1, min(maximumOpenFilePaths, 4_096))
    }

    public static let `default` = MacProcessCensusConfiguration()
}

public struct MacProcessCensusResult: Hashable, Sendable {
    public let processes: [AgentProcessSnapshot]
    public let gaps: [AgentDiscoveryGap]

    public init(processes: [AgentProcessSnapshot], gaps: [AgentDiscoveryGap]) {
        self.processes = processes
        self.gaps = gaps
    }
}

/// A passive, native process census. It never launches `ps`/`lsof`, opens a PTY,
/// sends a signal, or touches process input. Expensive FD inspection occurs only
/// after an argv/path classifier has identified a Codex, Claude, or Cursor candidate.
public struct MacProcessCensus: Sendable {
    public let configuration: MacProcessCensusConfiguration

    public init(configuration: MacProcessCensusConfiguration = .default) {
        self.configuration = configuration
    }

    public func scan() -> MacProcessCensusResult {
        let observedAt = agentUnixTimeNs()
        var gaps: [AgentDiscoveryGap] = []
        let (pids, processListTruncated) = listPIDs()
        if processListTruncated {
            gaps.append(AgentDiscoveryGap(kind: .processListTruncated))
        }

        var output: [AgentProcessSnapshot] = []
        output.reserveCapacity(min(pids.count, configuration.maximumAgentCandidates))

        for pid in pids where pid > 0 {
            if output.count >= configuration.maximumAgentCandidates {
                gaps.append(AgentDiscoveryGap(kind: .candidateProcessLimitReached))
                break
            }

            let name = copyString(capacity: 1_024) { buffer, capacity in
                mp_process_copy_name(pid, buffer, capacity)
            }
            let executable = copyString(capacity: 4_096) { buffer, capacity in
                mp_process_copy_executable_path(pid, buffer, capacity)
            }
            guard Self.mightBeAgent(name: name, executablePath: executable) else {
                continue
            }

            let argumentResult = copyArguments(pid: pid)
            guard let classification = Self.classify(
                name: name,
                executablePath: executable,
                arguments: argumentResult.values
            ) else {
                continue
            }

            var identity = mp_process_identity_t()
            guard mp_process_read_identity(pid, &identity) else { continue }

            let cwd = copyString(capacity: 4_096) { buffer, capacity in
                mp_process_copy_cwd(pid, buffer, capacity)
            }
            let tty = copyString(capacity: 1_024) { buffer, capacity in
                mp_process_copy_tty(pid, buffer, capacity)
            }
            let openFiles = copyOpenFilePaths(pid: pid)
            let classifiedTranscriptPaths = openFiles.values.compactMap { path -> (
                source: String,
                canonical: AgentCanonicalTranscriptPath
            )? in
                guard let canonical = AgentCanonicalTranscriptPath.classify(path),
                      canonical.provider == classification.provider
                else { return nil }
                return (Self.canonicalize(path), canonical)
            }
            let transcriptPaths = Array(Set(classifiedTranscriptPaths.map {
                $0.canonical.canonicalPath
            })).sorted()
            var transcriptWakePaths = Set<String>()
            for value in classifiedTranscriptPaths {
                switch value.canonical.provider {
                case .cursor:
                    if value.source == value.canonical.canonicalPath ||
                        value.source.hasSuffix("/store.db-wal")
                    {
                        transcriptWakePaths.insert(value.source)
                    }
                    transcriptWakePaths.insert(
                        URL(fileURLWithPath: value.canonical.canonicalPath)
                            .deletingLastPathComponent().path
                    )
                case .codex, .claude:
                    transcriptWakePaths.insert(value.canonical.canonicalPath)
                }
            }

            let foreground = identity.process_group_id > 0 &&
                identity.process_group_id == identity.terminal_process_group_id
            let role: AgentProcessRole = if classification.isHelper {
                .helper
            } else if !tty.isEmpty {
                .interactiveCandidate
            } else {
                .ambiguous
            }

            output.append(AgentProcessSnapshot(
                key: AgentProcessKey(
                    pid: identity.pid,
                    startTimeUnixNs: identity.start_time_unix_ns
                ),
                provider: classification.provider,
                role: role,
                parentPID: identity.parent_pid,
                processGroupID: identity.process_group_id,
                terminalProcessGroupID: identity.terminal_process_group_id,
                kernelStatus: identity.status,
                controllingTerminalDevice: identity.controlling_terminal_device,
                controllingTTY: tty.nilIfEmpty,
                cwd: Self.canonicalize(cwd).nilIfEmpty,
                executablePath: executable,
                arguments: argumentResult.values,
                openTranscriptPaths: transcriptPaths,
                transcriptWakePaths: transcriptWakePaths.sorted(),
                isForegroundTerminalProcess: foreground,
                argumentsTruncated: argumentResult.truncated,
                openFilesTruncated: openFiles.truncated,
                observedAtUnixNs: observedAt
            ))

            if argumentResult.truncated {
                gaps.append(AgentDiscoveryGap(
                    kind: .processArgumentsTruncated,
                    subject: String(pid)
                ))
            }
            if openFiles.truncated {
                gaps.append(AgentDiscoveryGap(
                    kind: .processOpenFilesTruncated,
                    subject: String(pid)
                ))
            }
        }

        output.sort {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            if $0.role != $1.role { return $0.role.rawValue < $1.role.rawValue }
            return $0.key.pid < $1.key.pid
        }
        return MacProcessCensusResult(processes: output, gaps: gaps)
    }

    private func listPIDs() -> ([Int32], Bool) {
        var values = [Int32](
            repeating: 0,
            count: configuration.maximumListedProcesses
        )
        var truncated = false
        let count = values.withUnsafeMutableBufferPointer { buffer in
            mp_process_list_pids(buffer.baseAddress, buffer.count, &truncated)
        }
        return (Array(values.prefix(Int(count))).filter { $0 > 0 }, truncated)
    }

    private func copyArguments(pid: Int32) -> (values: [String], truncated: Bool) {
        var bytes = [CChar](repeating: 0, count: configuration.maximumArgumentBytes)
        var count: UInt32 = 0
        var truncated = false
        let written = bytes.withUnsafeMutableBufferPointer { buffer in
            mp_process_copy_arguments(
                pid,
                buffer.baseAddress,
                buffer.count,
                &count,
                &truncated
            )
        }
        let values = Self.decodeNullSeparated(
            bytes: bytes,
            byteCount: Int(written),
            maximumValues: Int(count)
        )
        return (values, truncated)
    }

    private func copyOpenFilePaths(pid: Int32) -> (values: [String], truncated: Bool) {
        var bytes = [CChar](repeating: 0, count: configuration.maximumOpenFileBytes)
        var count: UInt32 = 0
        var truncated = false
        let written = bytes.withUnsafeMutableBufferPointer { buffer in
            mp_process_copy_open_file_paths(
                pid,
                buffer.baseAddress,
                buffer.count,
                configuration.maximumOpenFilePaths,
                &count,
                &truncated
            )
        }
        let values = Self.decodeNullSeparated(
            bytes: bytes,
            byteCount: Int(written),
            maximumValues: Int(count)
        )
        return (values, truncated)
    }

    private func copyString(
        capacity: Int,
        _ copier: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
    ) -> String {
        var bytes = [CChar](repeating: 0, count: capacity)
        let count = bytes.withUnsafeMutableBufferPointer { buffer in
            copier(buffer.baseAddress, buffer.count)
        }
        guard count > 0 else { return "" }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base)
        }
    }

    private static func decodeNullSeparated(
        bytes: [CChar],
        byteCount: Int,
        maximumValues: Int
    ) -> [String] {
        guard byteCount > 0, maximumValues > 0 else { return [] }
        return bytes.withUnsafeBytes { raw -> [String] in
            let values = raw.bindMemory(to: UInt8.self)
            let end = min(byteCount, values.count)
            var result: [String] = []
            result.reserveCapacity(min(maximumValues, 64))
            var start = 0
            while start < end, result.count < maximumValues {
                var cursor = start
                while cursor < end, values[cursor] != 0 { cursor += 1 }
                guard cursor < end else { break }
                if cursor > start {
                    result.append(String(decoding: values[start ..< cursor], as: UTF8.self))
                } else {
                    result.append("")
                }
                start = cursor + 1
            }
            return result
        }
    }

    private static func mightBeAgent(name: String, executablePath: String) -> Bool {
        let name = name.lowercased()
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return [name, executable].contains { value in
            value == "codex" || value == "claude" || value == "node" ||
                value == "nodejs" || value == "bun" || value == "deno" ||
                value == "agent"
        }
    }

    private static func classify(
        name: String,
        executablePath: String,
        arguments: [String]
    ) -> (provider: AgentProvider, isHelper: Bool)? {
        let executable = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        let processName = name.lowercased()
        let bounded = arguments.prefix(24).map { $0.lowercased() }

        let codex = processName == "codex" || executable == "codex" || bounded.contains { arg in
            let component = URL(fileURLWithPath: arg).lastPathComponent
            return component == "codex" || component == "codex.js" ||
                arg.contains("/@openai/codex/") || arg.contains("\\@openai\\codex\\")
        }
        let claude = processName == "claude" || executable == "claude" || bounded.contains { arg in
            let component = URL(fileURLWithPath: arg).lastPathComponent
            return component == "claude" || component == "claude.js" ||
                arg.contains("/@anthropic-ai/claude-code/") ||
                arg.contains("\\@anthropic-ai\\claude-code\\")
        }
        let cursor = bounded.contains { argument in
            argument.contains("/.local/share/cursor-agent/versions/") ||
                argument.contains("/cursor-agent/versions/")
        } && bounded.contains { argument in
            URL(fileURLWithPath: argument).lastPathComponent == "index.js"
        }
        let matches = [codex, claude, cursor].filter { $0 }.count
        guard matches == 1 else { return nil }
        let provider: AgentProvider = if codex {
            .codex
        } else if claude {
            .claude
        } else {
            .cursor
        }

        let helperMarkers: [String] = switch provider {
        case .codex:
            ["app-server", "sandbox-setup", "--codex-run-as-apply-patch", "node_repl"]
        case .claude:
            ["mcp-server", "--mcp-server", "claude-code-acp"]
        case .cursor:
            []
        }
        let helper = bounded.contains { argument in
            helperMarkers.contains { marker in argument.contains(marker) }
        }
        return (provider, helper)
    }

    private static func canonicalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
