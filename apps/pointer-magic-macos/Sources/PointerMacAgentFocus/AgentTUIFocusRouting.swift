import Foundation

public enum GhosttyFocusRouter {
    public static func route(
        canonicalWorkingDirectories: Set<String>,
        surfaces: [GhosttyTerminalSurface]
    ) -> AgentFocusRoutingResult<GhosttyTerminalSurface> {
        let matches = Array(Set(surfaces.filter {
            canonicalWorkingDirectories.contains($0.canonicalWorkingDirectory)
        }))
        switch matches.count {
        case 0: return .unavailable
        case 1: return .match(matches[0])
        default: return .ambiguous
        }
    }

    public static func parseSurfaces(
        _ value: AgentAppleScriptValue,
        canonicalize: (String) -> String?
    ) -> [GhosttyTerminalSurface] {
        guard case let .list(rows) = value else { return [] }
        return rows.compactMap { row in
            guard case let .list(columns) = row,
                  columns.count == 2,
                  case let .text(id) = columns[0],
                  case let .text(cwd) = columns[1],
                  !id.isEmpty,
                  let canonical = canonicalize(cwd),
                  !canonical.isEmpty
            else { return nil }
            return GhosttyTerminalSurface(
                id: id,
                workingDirectory: cwd,
                canonicalWorkingDirectory: canonical
            )
        }
    }
}

public enum GhosttyTTYFocusRouter {
    public static func route(
        ttys: Set<String>,
        surfaces: [GhosttyTTYTerminalSurface]
    ) -> AgentFocusRoutingResult<GhosttyTTYTerminalSurface> {
        let matches = Array(Set(surfaces.filter { ttys.contains($0.tty) }))
        switch matches.count {
        case 0: return .unavailable
        case 1: return .match(matches[0])
        default: return .ambiguous
        }
    }

    public static func route(
        surfaceID: String,
        surfaces: [GhosttyTerminalSurface]
    ) -> AgentFocusRoutingResult<GhosttyTerminalSurface> {
        let matches = Array(Set(surfaces.filter { $0.id == surfaceID }))
        switch matches.count {
        case 0: return .unavailable
        case 1: return .match(matches[0])
        default: return .ambiguous
        }
    }

    public static func parseSurfaces(_ value: AgentAppleScriptValue)
        -> [GhosttyTTYTerminalSurface]
    {
        guard case let .list(rows) = value else { return [] }
        return rows.compactMap { row in
            guard case let .list(columns) = row,
                  columns.count == 2,
                  case let .text(id) = columns[0],
                  case let .text(tty) = columns[1],
                  !id.isEmpty,
                  !tty.isEmpty
            else { return nil }
            return GhosttyTTYTerminalSurface(id: id, tty: tty)
        }
    }
}

public enum TerminalFocusRouter {
    public static func route(
        ttys: Set<String>,
        surfaces: [TerminalTabSurface]
    ) -> AgentFocusRoutingResult<TerminalTabSurface> {
        let matches = Array(Set(surfaces.filter { ttys.contains($0.tty) }))
        switch matches.count {
        case 0: return .unavailable
        case 1: return .match(matches[0])
        default: return .ambiguous
        }
    }

    public static func parseSurfaces(_ value: AgentAppleScriptValue) -> [TerminalTabSurface] {
        guard case let .list(rows) = value else { return [] }
        return rows.compactMap { row in
            guard case let .list(columns) = row,
                  columns.count == 3,
                  case let .integer(windowID) = columns[0],
                  case let .integer(tabIndex) = columns[1],
                  case let .text(tty) = columns[2],
                  windowID > 0,
                  tabIndex > 0,
                  !tty.isEmpty
            else { return nil }
            return TerminalTabSurface(windowID: windowID, tabIndex: tabIndex, tty: tty)
        }
    }
}

public enum AgentTUIFocusAppleScriptBuilder {
    /// Ghostty 1.4+ exposes Gtty. Raw four-character property syntax lets this
    /// source compile against 1.3; unsupported versions return -1728 and take
    /// the explicit compatibility route.
    public static let ghosttyTTYEnumeration = """
    if application id "com.mitchellh.ghostty" is not running then error "Ghostty is not running" number -600
    tell application id "com.mitchellh.ghostty"
        set surfaceRows to {}
        repeat with candidateTerminal in terminals
            set end of surfaceRows to {(id of candidateTerminal as text), («class Gtty» of candidateTerminal as text)}
        end repeat
        return surfaceRows
    end tell
    """

    public static let ghosttyEnumeration = """
    if application id "com.mitchellh.ghostty" is not running then error "Ghostty is not running" number -600
    tell application id "com.mitchellh.ghostty"
        set surfaceRows to {}
        repeat with candidateTerminal in terminals
            set end of surfaceRows to {(id of candidateTerminal as text), (working directory of candidateTerminal as text)}
        end repeat
        return surfaceRows
    end tell
    """

    public static let terminalEnumeration = """
    if application id "com.apple.Terminal" is not running then error "Terminal is not running" number -600
    tell application id "com.apple.Terminal"
        set surfaceRows to {}
        repeat with candidateWindow in windows
            set candidateWindowID to id of candidateWindow as integer
            set candidateTabIndex to 0
            repeat with candidateTab in tabs of candidateWindow
                set candidateTabIndex to candidateTabIndex + 1
                set end of surfaceRows to {candidateWindowID, candidateTabIndex, (tty of candidateTab as text)}
            end repeat
        end repeat
        return surfaceRows
    end tell
    """

    public static func ghosttyFocus(
        terminalID: String,
        expectedWorkingDirectory: String
    ) throws -> String {
        let id = try quote(terminalID)
        let cwd = try quote(expectedWorkingDirectory)
        return """
        if application id "com.mitchellh.ghostty" is not running then error "Ghostty is not running" number -600
        tell application id "com.mitchellh.ghostty"
            set expectedTerminalID to \(id)
            set expectedWorkingDirectory to \(cwd)
            set matchedTerminal to missing value
            set matchCount to 0
            repeat with candidateTerminal in terminals
                if (id of candidateTerminal as text) is expectedTerminalID and (working directory of candidateTerminal as text) is expectedWorkingDirectory then
                    set matchedTerminal to candidateTerminal
                    set matchCount to matchCount + 1
                end if
            end repeat
            if matchCount is 0 then error "Ghostty focus target disappeared" number -27001
            if matchCount is greater than 1 then error "Ghostty focus target became ambiguous" number -27002
            focus matchedTerminal
            activate
        end tell
        """
    }

    public static func ghosttyFocus(
        terminalID: String,
        expectedTTY: String
    ) throws -> String {
        let id = try quote(terminalID)
        let tty = try quote(expectedTTY)
        return """
        if application id "com.mitchellh.ghostty" is not running then error "Ghostty is not running" number -600
        tell application id "com.mitchellh.ghostty"
            set expectedTerminalID to \(id)
            set expectedTTY to \(tty)
            set matchedTerminal to missing value
            set matchCount to 0
            repeat with candidateTerminal in terminals
                if (id of candidateTerminal as text) is expectedTerminalID and («class Gtty» of candidateTerminal as text) is expectedTTY then
                    set matchedTerminal to candidateTerminal
                    set matchCount to matchCount + 1
                end if
            end repeat
            if matchCount is 0 then error "Ghostty focus target disappeared" number -27001
            if matchCount is greater than 1 then error "Ghostty focus target became ambiguous" number -27002
            focus matchedTerminal
            activate
        end tell
        """
    }

    public static func ghosttyFocus(terminalID: String) throws -> String {
        let id = try quote(terminalID)
        return """
        if application id "com.mitchellh.ghostty" is not running then error "Ghostty is not running" number -600
        tell application id "com.mitchellh.ghostty"
            set expectedTerminalID to \(id)
            set matchedTerminal to missing value
            set matchCount to 0
            repeat with candidateTerminal in terminals
                if (id of candidateTerminal as text) is expectedTerminalID then
                    set matchedTerminal to candidateTerminal
                    set matchCount to matchCount + 1
                end if
            end repeat
            if matchCount is 0 then error "Ghostty focus target disappeared" number -27001
            if matchCount is greater than 1 then error "Ghostty focus target became ambiguous" number -27002
            focus matchedTerminal
            activate
        end tell
        """
    }

    public static func terminalFocus(tty: String) throws -> String {
        let expectedTTY = try quote(tty)
        return """
        if application id "com.apple.Terminal" is not running then error "Terminal is not running" number -600
        tell application id "com.apple.Terminal"
            set expectedTTY to \(expectedTTY)
            set matchedWindow to missing value
            set matchedTab to missing value
            set matchCount to 0
            repeat with candidateWindow in windows
                repeat with candidateTab in tabs of candidateWindow
                    if (tty of candidateTab as text) is expectedTTY then
                        set matchedWindow to candidateWindow
                        set matchedTab to candidateTab
                        set matchCount to matchCount + 1
                    end if
                end repeat
            end repeat
            if matchCount is 0 then error "Terminal focus target disappeared" number -27001
            if matchCount is greater than 1 then error "Terminal focus target became ambiguous" number -27002
            set selected of matchedTab to true
            set index of matchedWindow to 1
            activate
        end tell
        """
    }

    private static func quote(_ value: String) throws -> String {
        guard !value.isEmpty else { throw AgentFocusScriptBuildError.emptyValue }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }) else {
            throw AgentFocusScriptBuildError.unsafeControlCharacter
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
