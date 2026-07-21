import Foundation
import PointerAgentContracts

public enum AgentTUIFocusDestination: Hashable, Sendable {
    case ghostty(terminalID: String)
    case terminal(tty: String)
    /// Best-effort activation of the Cursor app when the agent is not hosted in
    /// Ghostty or Terminal (for example Cursor's own agent panel / PTY).
    case cursorApp
}

public enum AgentTUIFocusUnavailableReason: String, Hashable, Sendable {
    case sessionNotLive
    case noLiveProcess
    case hostBootChanged
    case processExited
    case processIdentityChanged
    case processTerminalChanged
    case terminalApplicationNotRunning
    case noMatchingSurface
    case ambiguousSurface
    case missingActionTimeWorkingDirectory
    case terminalIdentityUnavailable
}

public struct AgentTUIFocusFailure: Error, Hashable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = String(message.prefix(512))
    }
}

public enum AgentTUIFocusResult: Hashable, Sendable {
    case focused(AgentTUIFocusDestination)
    case unavailable(AgentTUIFocusUnavailableReason)
    case permissionDenied
    case failed(AgentTUIFocusFailure)
}

public enum AgentTerminalApplication: String, CaseIterable, Hashable, Sendable {
    case ghostty
    case terminal

    public var bundleIdentifier: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .terminal: "com.apple.Terminal"
        }
    }
}

/// The terminal application proven by the live process ancestry. `unknown` is
/// intentionally a first-class state: focus must not invent Terminal or Cursor
/// from the agent provider name alone.
public enum AgentTerminalOwner: String, Hashable, Sendable {
    case ghostty
    case terminal
    /// Cursor.app appears in the process ancestry (IDE-hosted agent).
    case cursor
    case unknown

    public var application: AgentTerminalApplication? {
        switch self {
        case .ghostty: .ghostty
        case .terminal: .terminal
        case .cursor, .unknown: nil
        }
    }

    public var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .cursor: "Cursor"
        case .unknown: "terminal"
        }
    }
}

public struct RevalidatedAgentProcess: Hashable, Sendable {
    public let identity: AgentProcessInstanceIdentity
    public let canonicalWorkingDirectory: String?
    public let tty: String?
    public let terminalOwner: AgentTerminalOwner

    public init(
        identity: AgentProcessInstanceIdentity,
        canonicalWorkingDirectory: String?,
        tty: String?,
        terminalOwner: AgentTerminalOwner
    ) {
        self.identity = identity
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
        self.tty = tty
        self.terminalOwner = terminalOwner
    }
}

public enum AgentProcessRevalidationResult: Hashable, Sendable {
    case valid(RevalidatedAgentProcess)
    case hostBootChanged
    case processExited
    case processIdentityChanged
    case terminalChanged
}

public protocol AgentProcessFocusRevalidating: Sendable {
    func revalidate(_ process: AgentProcessInstance) -> AgentProcessRevalidationResult
}

public protocol AgentTerminalApplicationQuerying: Sendable {
    func isRunning(_ application: AgentTerminalApplication) -> Bool
}

public indirect enum AgentAppleScriptValue: Equatable, Sendable {
    case text(String)
    case integer(Int)
    case list([AgentAppleScriptValue])
    case missing
}

public struct AgentAppleScriptExecutionFailure: Error, Hashable, Sendable {
    public let number: Int
    public let message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = String(message.prefix(512))
    }

    public var isPermissionDenied: Bool { number == -1743 }
}

public protocol AgentAppleScriptExecuting: Sendable {
    func execute(_ source: String) async throws -> AgentAppleScriptValue
}

public enum AgentFocusRoutingResult<Surface: Hashable & Sendable>: Hashable, Sendable {
    case match(Surface)
    case unavailable
    case ambiguous
}

public struct GhosttyTerminalSurface: Hashable, Sendable {
    public let id: String
    public let workingDirectory: String
    public let canonicalWorkingDirectory: String

    public init(id: String, workingDirectory: String, canonicalWorkingDirectory: String) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.canonicalWorkingDirectory = canonicalWorkingDirectory
    }
}

/// A Ghostty surface identified by the PTY device that owns the agent process.
/// Ghostty exposes this beginning with its 1.4 AppleScript API. Keeping this
/// separate from the CWD compatibility surface prevents a mutable folder from
/// being mistaken for process identity.
public struct GhosttyTTYTerminalSurface: Hashable, Sendable {
    public let id: String
    public let tty: String

    public init(id: String, tty: String) {
        self.id = id
        self.tty = tty
    }
}

public struct TerminalTabSurface: Hashable, Sendable {
    public let windowID: Int
    public let tabIndex: Int
    public let tty: String

    public init(windowID: Int, tabIndex: Int, tty: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.tty = tty
    }
}

public enum AgentFocusScriptBuildError: Error, Equatable, Sendable {
    case emptyValue
    case unsafeControlCharacter
}
