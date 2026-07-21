@preconcurrency import AppKit
import Darwin
import Foundation
import PointerAgentContracts
import PointerC

public struct NativeAgentProcessFocusRevalidator: AgentProcessFocusRevalidating {
    public init() {}

    public func revalidate(_ process: AgentProcessInstance) -> AgentProcessRevalidationResult {
        guard let bootID = Self.currentBootID(),
              bootID == process.identity.hostBootID
        else { return .hostBootChanged }

        var identity = mp_process_identity_t()
        guard mp_process_read_identity(process.identity.pid, &identity) else {
            return .processExited
        }
        guard identity.start_time_unix_ns == process.identity.startedAtUnixNs else {
            return .processIdentityChanged
        }

        let liveTTY = copyString(capacity: 1_024) { buffer, capacity in
            mp_process_copy_tty(process.identity.pid, buffer, capacity)
        }
        if let observedTTY = process.tty,
           !observedTTY.isEmpty,
           observedTTY != liveTTY
        {
            return .terminalChanged
        }
        let liveCWD = copyString(capacity: 4_096) { buffer, capacity in
            mp_process_copy_cwd(process.identity.pid, buffer, capacity)
        }
        let terminalOwner = terminalOwner(startingAt: identity)
        return .valid(RevalidatedAgentProcess(
            identity: process.identity,
            canonicalWorkingDirectory: Self.canonicalize(liveCWD),
            tty: liveTTY.isEmpty ? nil : liveTTY,
            terminalOwner: terminalOwner
        ))
    }

    /// Reads every hop from the kernel at action time. A missing hop, a reused
    /// PID, a loop, or an ancestry that does not reach a supported app is
    /// deliberately `unknown`; callers must not discover an owner by probing apps.
    private func terminalOwner(
        startingAt initialIdentity: mp_process_identity_t
    ) -> AgentTerminalOwner {
        var cursor = initialIdentity
        var visited: Set<Int32> = []

        for _ in 0 ..< 64 {
            guard cursor.pid > 0, visited.insert(cursor.pid).inserted else {
                return .unknown
            }

            let executablePath = copyString(capacity: 4_096) { buffer, capacity in
                mp_process_copy_executable_path(cursor.pid, buffer, capacity)
            }

            // Confirm that the path and parent edge belonged to the same process
            // incarnation we just inspected.
            var confirmed = mp_process_identity_t()
            guard mp_process_read_identity(cursor.pid, &confirmed),
                  confirmed.pid == cursor.pid,
                  confirmed.start_time_unix_ns == cursor.start_time_unix_ns,
                  confirmed.parent_pid == cursor.parent_pid
            else { return .unknown }

            if let owner = Self.classifyTerminalOwner(executablePath: executablePath) {
                return owner
            }

            let parentPID = confirmed.parent_pid
            guard parentPID > 1 else { return .unknown }

            var parent = mp_process_identity_t()
            guard mp_process_read_identity(parentPID, &parent),
                  parent.pid == parentPID,
                  parent.start_time_unix_ns <= confirmed.start_time_unix_ns
            else { return .unknown }
            cursor = parent
        }
        return .unknown
    }

    static func classifyTerminalOwner(executablePath: String) -> AgentTerminalOwner? {
        let path = executablePath.lowercased()
        if path.hasSuffix("/ghostty.app/contents/macos/ghostty") {
            return .ghostty
        }
        if path.hasSuffix("/terminal.app/contents/macos/terminal") {
            return .terminal
        }
        // Cursor IDE ships as Cursor.app; CLI cursor-agent under Ghostty/Terminal
        // must keep walking and must not be classified from the provider name.
        if path.hasSuffix("/cursor.app/contents/macos/cursor") {
            return .cursor
        }
        return nil
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

    private static func currentBootID() -> UUID? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1
        else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let string = String(
            decoding: bytes[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return UUID(uuidString: string)
    }

    private static func canonicalize(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url: URL
        if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
            url = fileURL
        } else {
            url = URL(fileURLWithPath: path)
        }
        let value = url.standardizedFileURL.resolvingSymlinksInPath().path
        return value.isEmpty ? nil : value
    }
}

public struct RunningAgentTerminalApplicationQuery: AgentTerminalApplicationQuerying {
    public init() {}

    public func isRunning(_ application: AgentTerminalApplication) -> Bool {
        if !NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).isEmpty {
            return true
        }
        // Bundle-id lookup is preferred, but path/name is a second live check so a
        // mismatched catalog entry cannot invent "not running" for a visible app.
        let expectedName: String = switch application {
        case .ghostty: "Ghostty.app"
        case .terminal: "Terminal.app"
        }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent == expectedName
        }
    }
}

public final class NativeAgentAppleScriptExecutor: AgentAppleScriptExecuting,
    @unchecked Sendable
{
    private static let timeoutNanoseconds: UInt64 = 4_000_000_000

    public init() {}

    public func execute(_ source: String) async throws -> AgentAppleScriptValue {
        try await withThrowingTaskGroup(of: AgentAppleScriptValue.self) { group in
            group.addTask {
                try await self.executeOnce(source)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                throw AgentAppleScriptExecutionFailure(
                    number: -1712,
                    message: "Timed out waiting for terminal automation"
                )
            }
            // First finished child wins. A hung NSAppleScript cannot be cancelled,
            // but the shelf must not wait on it indefinitely.
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func executeOnce(_ source: String) async throws -> AgentAppleScriptValue {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: AgentAppleScriptExecutionFailure(
                        number: -2700,
                        message: "AppleScript could not be compiled"
                    ))
                    return
                }
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if let error {
                    let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                        ?? (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
                        ?? -2700
                    let message = error[NSAppleScript.errorMessage] as? String
                        ?? error["NSAppleScriptErrorMessage"] as? String
                        ?? "AppleScript failed"
                    continuation.resume(throwing: AgentAppleScriptExecutionFailure(
                        number: number,
                        message: message
                    ))
                    return
                }
                continuation.resume(returning: Self.value(from: result))
            }
        }
    }

    private static func value(from descriptor: NSAppleEventDescriptor) -> AgentAppleScriptValue {
        let itemCount = descriptor.numberOfItems
        if itemCount > 0 {
            let values = (1 ... itemCount).compactMap { index in
                descriptor.atIndex(index).map(value(from:))
            }
            return .list(values)
        }
        if descriptor.descriptorType == typeSInt16 ||
            descriptor.descriptorType == typeSInt32 ||
            descriptor.descriptorType == typeUInt32 ||
            descriptor.descriptorType == typeSInt64
        {
            return .integer(Int(descriptor.int32Value))
        }
        if let string = descriptor.stringValue { return .text(string) }
        return .missing
    }
}

/// Explicit action adapter. It owns no observation loop and cannot type, paste,
/// submit, spawn, or resume an agent. Every call revalidates the process incarnation
/// and re-enumerates the destination surface immediately before the focus command.
@MainActor
public final class MacAgentTUIFocusController {
    private let processRevalidator: any AgentProcessFocusRevalidating
    private let applicationQuery: any AgentTerminalApplicationQuerying
    private let appleScript: any AgentAppleScriptExecuting

    public init(
        processRevalidator: any AgentProcessFocusRevalidating =
            NativeAgentProcessFocusRevalidator(),
        applicationQuery: any AgentTerminalApplicationQuerying =
            RunningAgentTerminalApplicationQuery(),
        appleScript: any AgentAppleScriptExecuting = NativeAgentAppleScriptExecutor()
    ) {
        self.processRevalidator = processRevalidator
        self.applicationQuery = applicationQuery
        self.appleScript = appleScript
    }

    public func focus(_ session: AgentSessionSnapshot) async -> AgentTUIFocusResult {
        guard session.liveness == .live else { return .unavailable(.sessionNotLive) }
        let processes = session.processes
            .filter { $0.liveness == .live }
            .map(\.process)
        guard !processes.isEmpty else { return .unavailable(.noLiveProcess) }

        let revalidator = processRevalidator
        let validation = await Task.detached(priority: .userInitiated) {
            processes.map { revalidator.revalidate($0) }
        }.value
        let live = validation.compactMap { result -> RevalidatedAgentProcess? in
            guard case let .valid(process) = result else { return nil }
            return process
        }
        guard !live.isEmpty else { return .unavailable(revalidationFailure(validation)) }

        let knownOwners = Set(
            live.map(\.terminalOwner).filter { $0 != .unknown }
        )
        if knownOwners.isEmpty {
            // Ancestry did not reach a known host. Use live TTYs against apps that
            // are actually running — never invent Terminal/Cursor from provider.
            return await focusByTTYEvidence(live: live, processes: processes)
        }
        guard knownOwners.count == 1, let owner = knownOwners.first else {
            return .unavailable(.ambiguousSurface)
        }

        switch owner {
        case .terminal:
            return await focusTerminal(live: live, processes: processes)
        case .ghostty:
            return await focusGhostty(live: live, processes: processes)
        case .cursor:
            return focusCursorApplication()
        case .unknown:
            return await focusByTTYEvidence(live: live, processes: processes)
        }
    }

    /// When ancestry is inconclusive, match the agent's PTY against hosts that are
    /// observably running. Tries every running host until a TTY matches — never
    /// prefers Ghostty/Terminal from agent provider (Codex/Claude/Cursor/other).
    private func focusByTTYEvidence(
        live: [RevalidatedAgentProcess],
        processes: [AgentProcessInstance]
    ) async -> AgentTUIFocusResult {
        let ttys = Set(live.compactMap(\.tty)).filter { !$0.isEmpty }
        guard !ttys.isEmpty else {
            return .unavailable(.noMatchingSurface)
        }

        var hosts: [AgentTerminalApplication] = []
        if applicationQuery.isRunning(.ghostty) { hosts.append(.ghostty) }
        if applicationQuery.isRunning(.terminal) { hosts.append(.terminal) }
        guard !hosts.isEmpty else {
            return .failed(AgentTUIFocusFailure(
                code: -600,
                message: "No running Ghostty or Terminal hosts this agent"
            ))
        }

        var lastMiss: AgentTUIFocusResult = .unavailable(.noMatchingSurface)
        for host in hosts {
            let result: AgentTUIFocusResult = switch host {
            case .ghostty:
                await focusGhostty(
                    live: live,
                    processes: processes,
                    ownerFilter: nil
                )
            case .terminal:
                await focusTerminal(
                    live: live,
                    processes: processes,
                    ownerFilter: nil
                )
            }
            switch result {
            case .focused:
                return result
            case .unavailable(.ambiguousSurface):
                // A proven ambiguous match on one host is authoritative.
                return result
            case .unavailable(.noMatchingSurface),
                 .unavailable(.terminalIdentityUnavailable),
                 .unavailable(.missingActionTimeWorkingDirectory):
                lastMiss = result
                continue
            default:
                // Permission / timeout / hard failure: keep looking at the other
                // running host before surfacing the error.
                lastMiss = result
                continue
            }
        }
        return lastMiss
    }

    private func focusCursorApplication() -> AgentTUIFocusResult {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.lastPathComponent == "Cursor.app" || $0.localizedName == "Cursor"
        }) else {
            return .failed(AgentTUIFocusFailure(
                code: -600,
                message: "Cursor is not running"
            ))
        }
        let activated = app.activate()
        return activated
            ? .focused(.cursorApp)
            : .failed(AgentTUIFocusFailure(code: -1, message: "Could not activate Cursor"))
    }

    private func notRunning(_ owner: AgentTerminalOwner) -> AgentTUIFocusResult {
        .failed(AgentTUIFocusFailure(
            code: -600,
            message: "\(owner.displayName) is not running"
        ))
    }

    private func focusTerminal(
        live: [RevalidatedAgentProcess],
        processes: [AgentProcessInstance],
        ownerFilter: AgentTerminalOwner? = .terminal
    ) async -> AgentTUIFocusResult {
        guard applicationQuery.isRunning(.terminal) else {
            return notRunning(.terminal)
        }
        let candidates = live.filter { process in
            guard let ownerFilter else { return process.tty != nil }
            return process.terminalOwner == ownerFilter
        }
        let ttys = Set(candidates.compactMap(\.tty)).filter { !$0.isEmpty }
        guard !ttys.isEmpty else { return .unavailable(.noMatchingSurface) }

        do {
            let value = try await appleScript.execute(
                AgentTUIFocusAppleScriptBuilder.terminalEnumeration
            )
            switch TerminalFocusRouter.route(
                ttys: ttys,
                surfaces: TerminalFocusRouter.parseSurfaces(value)
            ) {
            case let .match(surface):
                let relevantIDs = Set(candidates.filter {
                    $0.tty == surface.tty
                }.map(\.identity))
                let actionValidation = await revalidateForAction(
                    processes.filter { relevantIDs.contains($0.identity) }
                )
                guard actionValidation.contains(where: { result in
                    guard case let .valid(process) = result else { return false }
                    guard process.tty == surface.tty else { return false }
                    if let ownerFilter { return process.terminalOwner == ownerFilter }
                    return process.terminalOwner == .terminal || process.terminalOwner == .unknown
                }) else {
                    return .unavailable(actionRevalidationFailure(
                        actionValidation,
                        expectedOwner: .terminal,
                        ownerMatchedFailure: .processTerminalChanged
                    ))
                }
                guard applicationQuery.isRunning(.terminal) else {
                    return notRunning(.terminal)
                }
                let script = try AgentTUIFocusAppleScriptBuilder.terminalFocus(
                    tty: surface.tty
                )
                _ = try await appleScript.execute(script)
                return .focused(.terminal(tty: surface.tty))
            case .ambiguous:
                return .unavailable(.ambiguousSurface)
            case .unavailable:
                return .unavailable(.noMatchingSurface)
            }
        } catch {
            return map(error, preferredOwner: .terminal)
        }
    }

    private func focusGhostty(
        live: [RevalidatedAgentProcess],
        processes: [AgentProcessInstance],
        ownerFilter: AgentTerminalOwner? = .ghostty
    ) async -> AgentTUIFocusResult {
        guard applicationQuery.isRunning(.ghostty) else {
            return notRunning(.ghostty)
        }
        let ghosttyLive = live.filter { process in
            guard let ownerFilter else { return process.tty != nil }
            return process.terminalOwner == ownerFilter
        }
        let ttys = Set(ghosttyLive.compactMap(\.tty)).filter { !$0.isEmpty }
        guard !ttys.isEmpty else { return .unavailable(.noMatchingSurface) }

        // Ghostty 1.4+ exposes the PTY path for every surface. It is the only
        // authoritative join from the live agent process to a Ghostty UUID.
        // Version 1.3 returns -1728 for Gtty; only that explicit capability gap
        // may enter the exact-CWD compatibility path below.
        do {
            let value = try await appleScript.execute(
                AgentTUIFocusAppleScriptBuilder.ghosttyTTYEnumeration
            )
            switch GhosttyTTYFocusRouter.route(
                ttys: ttys,
                surfaces: GhosttyTTYFocusRouter.parseSurfaces(value)
            ) {
            case let .match(surface):
                return await focusGhosttyTTY(
                    surface,
                    live: ghosttyLive,
                    processes: processes,
                    ownerFilter: ownerFilter
                )
            case .ambiguous:
                return .unavailable(.ambiguousSurface)
            case .unavailable:
                return .unavailable(.noMatchingSurface)
            }
        } catch let failure as AgentAppleScriptExecutionFailure
            where failure.number == -1728
        {
            // Installed Ghostty lacks the TTY property. Continue to the narrow
            // 1.3 compatibility path; it still fails closed on zero/duplicates.
        } catch {
            return map(error, preferredOwner: .ghostty)
        }

        return await focusGhosttyByWorkingDirectory(
            live: ghosttyLive,
            processes: processes,
            ownerFilter: ownerFilter
        )
    }

    private func focusGhosttyTTY(
        _ surface: GhosttyTTYTerminalSurface,
        live: [RevalidatedAgentProcess],
        processes: [AgentProcessInstance],
        ownerFilter: AgentTerminalOwner? = .ghostty
    ) async -> AgentTUIFocusResult {
        let relevantIDs = Set(live.filter { $0.tty == surface.tty }.map(\.identity))
        let actionValidation = await revalidateForAction(
            processes.filter { relevantIDs.contains($0.identity) }
        )
        guard actionValidation.contains(where: { result in
            guard case let .valid(process) = result else { return false }
            guard process.tty == surface.tty else { return false }
            if let ownerFilter { return process.terminalOwner == ownerFilter }
            return process.terminalOwner == .ghostty || process.terminalOwner == .unknown
        }) else {
            return .unavailable(actionRevalidationFailure(
                actionValidation,
                expectedOwner: .ghostty,
                ownerMatchedFailure: .processTerminalChanged
            ))
        }
        guard applicationQuery.isRunning(.ghostty) else {
            return notRunning(.ghostty)
        }

        do {
            let script = try AgentTUIFocusAppleScriptBuilder.ghosttyFocus(
                terminalID: surface.id,
                expectedTTY: surface.tty
            )
            _ = try await appleScript.execute(script)
            return .focused(.ghostty(terminalID: surface.id))
        } catch {
            return map(error, preferredOwner: .ghostty)
        }
    }

    private func focusGhosttyByWorkingDirectory(
        live: [RevalidatedAgentProcess],
        processes: [AgentProcessInstance],
        ownerFilter: AgentTerminalOwner? = .ghostty
    ) async -> AgentTUIFocusResult {
        let cwds = Set(live.compactMap(\.canonicalWorkingDirectory))
        guard !cwds.isEmpty else {
            return .unavailable(.missingActionTimeWorkingDirectory)
        }

        do {
            let value = try await appleScript.execute(
                AgentTUIFocusAppleScriptBuilder.ghosttyEnumeration
            )
            let surfaces = GhosttyFocusRouter.parseSurfaces(
                value,
                canonicalize: Self.canonicalize
            )
            switch GhosttyFocusRouter.route(
                canonicalWorkingDirectories: cwds,
                surfaces: surfaces
            ) {
            case let .match(surface):
                let relevantIDs = Set(live.filter { process in
                    let ownerOK: Bool
                    if let ownerFilter {
                        ownerOK = process.terminalOwner == ownerFilter
                    } else {
                        ownerOK = process.terminalOwner == .ghostty
                            || process.terminalOwner == .unknown
                    }
                    return ownerOK &&
                        process.canonicalWorkingDirectory == surface.canonicalWorkingDirectory
                }.map(\.identity))
                let actionValidation = await revalidateForAction(
                    processes.filter { relevantIDs.contains($0.identity) }
                )
                guard actionValidation.contains(where: { result in
                    guard case let .valid(process) = result else { return false }
                    guard process.canonicalWorkingDirectory == surface.canonicalWorkingDirectory
                    else { return false }
                    if let ownerFilter { return process.terminalOwner == ownerFilter }
                    return process.terminalOwner == .ghostty || process.terminalOwner == .unknown
                }) else {
                    return .unavailable(actionRevalidationFailure(
                        actionValidation,
                        expectedOwner: .ghostty,
                        ownerMatchedFailure: .noMatchingSurface
                    ))
                }
                guard applicationQuery.isRunning(.ghostty) else {
                    return notRunning(.ghostty)
                }
                let script = try AgentTUIFocusAppleScriptBuilder.ghosttyFocus(
                    terminalID: surface.id,
                    expectedWorkingDirectory: surface.workingDirectory
                )
                _ = try await appleScript.execute(script)
                return .focused(.ghostty(terminalID: surface.id))
            case .ambiguous:
                return .unavailable(.ambiguousSurface)
            case .unavailable:
                return .unavailable(.terminalIdentityUnavailable)
            }
        } catch {
            return map(error, preferredOwner: .ghostty)
        }
    }

    private func revalidationFailure(
        _ values: [AgentProcessRevalidationResult]
    ) -> AgentTUIFocusUnavailableReason {
        if values.contains(.hostBootChanged) { return .hostBootChanged }
        if values.contains(.processIdentityChanged) { return .processIdentityChanged }
        if values.contains(.terminalChanged) { return .processTerminalChanged }
        return .processExited
    }

    private func actionRevalidationFailure(
        _ values: [AgentProcessRevalidationResult],
        expectedOwner: AgentTerminalOwner,
        ownerMatchedFailure: AgentTUIFocusUnavailableReason
    ) -> AgentTUIFocusUnavailableReason {
        let valid = values.compactMap { result -> RevalidatedAgentProcess? in
            guard case let .valid(process) = result else { return nil }
            return process
        }
        guard !valid.isEmpty else { return revalidationFailure(values) }

        let knownOwners = Set(
            valid.map(\.terminalOwner).filter { $0 != .unknown }
        )
        if knownOwners.isEmpty { return .noMatchingSurface }
        if knownOwners != [expectedOwner] { return .ambiguousSurface }
        return ownerMatchedFailure
    }

    private func revalidateForAction(
        _ processes: [AgentProcessInstance]
    ) async -> [AgentProcessRevalidationResult] {
        guard !processes.isEmpty else { return [.processExited] }
        let revalidator = processRevalidator
        return await Task.detached(priority: .userInitiated) {
            processes.map { revalidator.revalidate($0) }
        }.value
    }

    private func map(
        _ error: Error,
        preferredOwner: AgentTerminalOwner? = nil
    ) -> AgentTUIFocusResult {
        if let failure = error as? AgentAppleScriptExecutionFailure {
            if failure.isPermissionDenied { return .permissionDenied }
            // Timeout while waiting for Automation / a stuck terminal script.
            if failure.number == -1712 {
                return .failed(AgentTUIFocusFailure(
                    code: -1712,
                    message: preferredOwner.map {
                        "Timed out waiting for \($0.displayName) automation"
                    } ?? "Timed out waiting for terminal automation"
                ))
            }
            if failure.number == -600 {
                if let preferredOwner { return notRunning(preferredOwner) }
                return .failed(AgentTUIFocusFailure(
                    code: -600,
                    message: failure.message
                ))
            }
            if failure.number == -27002 { return .unavailable(.ambiguousSurface) }
            if failure.number == -27001 || failure.number == -1728 {
                return .unavailable(.noMatchingSurface)
            }
            return .failed(AgentTUIFocusFailure(
                code: failure.number,
                message: failure.message
            ))
        }
        if let build = error as? AgentFocusScriptBuildError {
            return .failed(AgentTUIFocusFailure(code: -50, message: String(describing: build)))
        }
        return .failed(AgentTUIFocusFailure(code: -1, message: String(describing: error)))
    }

    private static func canonicalize(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url: URL
        if path.hasPrefix("file://"), let fileURL = URL(string: path), fileURL.isFileURL {
            url = fileURL
        } else {
            url = URL(fileURLWithPath: path)
        }
        let result = url.standardizedFileURL.resolvingSymlinksInPath().path
        return result.isEmpty ? nil : result
    }
}
