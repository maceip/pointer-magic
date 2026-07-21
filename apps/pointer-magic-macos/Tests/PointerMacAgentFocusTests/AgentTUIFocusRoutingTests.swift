import Foundation
import PointerAgentContracts
import Testing
@testable import PointerMacAgentFocus

@Suite("Agent TUI focus routing")
struct AgentTUIFocusRoutingTests {
    @Test("Ghostty requires exactly one canonical cwd match")
    func ghosttyUniqueCanonicalMatch() {
        let surfaces = [
            GhosttyTerminalSurface(
                id: "one",
                workingDirectory: "/tmp/link",
                canonicalWorkingDirectory: "/private/tmp/project"
            ),
            GhosttyTerminalSurface(
                id: "two",
                workingDirectory: "/Users/example/elsewhere",
                canonicalWorkingDirectory: "/Users/example/elsewhere"
            ),
        ]
        let result = GhosttyFocusRouter.route(
            canonicalWorkingDirectories: ["/private/tmp/project"],
            surfaces: surfaces
        )
        #expect(result == .match(surfaces[0]))
    }

    @Test("Ghostty fails closed when two terminals share the cwd")
    func ghosttyAmbiguity() {
        let surfaces = [
            GhosttyTerminalSurface(
                id: "one",
                workingDirectory: "/work",
                canonicalWorkingDirectory: "/work"
            ),
            GhosttyTerminalSurface(
                id: "two",
                workingDirectory: "/work/.",
                canonicalWorkingDirectory: "/work"
            ),
        ]
        #expect(GhosttyFocusRouter.route(
            canonicalWorkingDirectories: ["/work"],
            surfaces: surfaces
        ) == .ambiguous)
    }

    @Test("Terminal routes by exact TTY and rejects duplicate matches")
    func terminalExactTTY() {
        let one = TerminalTabSurface(windowID: 1, tabIndex: 1, tty: "/dev/ttys007")
        let other = TerminalTabSurface(windowID: 2, tabIndex: 1, tty: "/dev/ttys008")
        #expect(TerminalFocusRouter.route(
            ttys: ["/dev/ttys007"],
            surfaces: [one, other]
        ) == .match(one))

        let duplicate = TerminalTabSurface(windowID: 3, tabIndex: 2, tty: "/dev/ttys007")
        #expect(TerminalFocusRouter.route(
            ttys: ["/dev/ttys007"],
            surfaces: [one, duplicate]
        ) == .ambiguous)
    }

    @Test("Ghostty routes by exact TTY and rejects duplicate matches")
    func ghosttyExactTTY() {
        let one = GhosttyTTYTerminalSurface(id: "one", tty: "/dev/ttys007")
        let other = GhosttyTTYTerminalSurface(id: "two", tty: "/dev/ttys008")
        #expect(GhosttyTTYFocusRouter.route(
            ttys: ["/dev/ttys007"],
            surfaces: [one, other]
        ) == .match(one))

        let duplicate = GhosttyTTYTerminalSurface(id: "three", tty: "/dev/ttys007")
        #expect(GhosttyTTYFocusRouter.route(
            ttys: ["/dev/ttys007"],
            surfaces: [one, duplicate]
        ) == .ambiguous)
    }

    @Test("Enumeration descriptors are parsed without lossy line encoding")
    func descriptorParsing() {
        let ghostty = AgentAppleScriptValue.list([
            .list([.text("terminal-id"), .text("/work")]),
            .list([.text("malformed")]),
        ])
        let ghosttyRows = GhosttyFocusRouter.parseSurfaces(ghostty) { value in
            value == "/work" ? "/canonical/work" : nil
        }
        #expect(ghosttyRows == [GhosttyTerminalSurface(
            id: "terminal-id",
            workingDirectory: "/work",
            canonicalWorkingDirectory: "/canonical/work"
        )])

        let ghosttyTTY = AgentAppleScriptValue.list([
            .list([.text("terminal-id"), .text("/dev/ttys009")]),
        ])
        #expect(GhosttyTTYFocusRouter.parseSurfaces(ghosttyTTY) == [
            GhosttyTTYTerminalSurface(id: "terminal-id", tty: "/dev/ttys009"),
        ])

        let terminal = AgentAppleScriptValue.list([
            .list([.integer(7), .integer(2), .text("/dev/ttys004")]),
        ])
        #expect(TerminalFocusRouter.parseSurfaces(terminal) == [
            TerminalTabSurface(windowID: 7, tabIndex: 2, tty: "/dev/ttys004"),
        ])
    }

    @Test("Generated scripts contain focus only and revalidate their target")
    func focusOnlyScripts() throws {
        let ghostty = try AgentTUIFocusAppleScriptBuilder.ghosttyFocus(
            terminalID: "surface-1",
            expectedWorkingDirectory: "/Users/example/project"
        )
        let ghosttyTTY = try AgentTUIFocusAppleScriptBuilder.ghosttyFocus(
            terminalID: "surface-1",
            expectedTTY: "/dev/ttys004"
        )
        let terminal = try AgentTUIFocusAppleScriptBuilder.terminalFocus(
            tty: "/dev/ttys004"
        )
        let scripts = [
            AgentTUIFocusAppleScriptBuilder.ghosttyTTYEnumeration,
            AgentTUIFocusAppleScriptBuilder.ghosttyEnumeration,
            AgentTUIFocusAppleScriptBuilder.terminalEnumeration,
            ghostty,
            ghosttyTTY,
            terminal,
        ]
        let forbidden = [
            "input text", "send key", "do script", "clipboard", "keystroke",
            "perform action",
        ]
        for script in scripts {
            let lowered = script.lowercased()
            for token in forbidden { #expect(!lowered.contains(token)) }
        }
        #expect(ghostty.contains("matchCount is 0"))
        #expect(ghostty.contains("matchCount is greater than 1"))
        #expect(ghostty.contains("working directory of candidateTerminal"))
        #expect(ghostty.contains("focus matchedTerminal"))
        #expect(ghostty.contains("activate"))
        #expect(ghosttyTTY.contains("«class Gtty» of candidateTerminal"))
        #expect(ghosttyTTY.contains("focus matchedTerminal"))
        #expect(terminal.contains("tty of candidateTab"))
        #expect(terminal.contains("set selected of matchedTab to true"))
        #expect(terminal.contains("set index of matchedWindow to 1"))
    }

    @Test("Unsafe script values are rejected rather than interpolated")
    func unsafeValuesRejected() {
        #expect(throws: AgentFocusScriptBuildError.unsafeControlCharacter) {
            _ = try AgentTUIFocusAppleScriptBuilder.terminalFocus(
                tty: "/dev/ttys001\nend tell"
            )
        }
        #expect(throws: AgentFocusScriptBuildError.emptyValue) {
            _ = try AgentTUIFocusAppleScriptBuilder.ghosttyFocus(
                terminalID: "",
                expectedWorkingDirectory: "/work"
            )
        }
    }

    @Test("Terminal owner classifier recognizes app-bundle executables only")
    func terminalOwnerClassification() {
        #expect(NativeAgentProcessFocusRevalidator.classifyTerminalOwner(
            executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        ) == .ghostty)
        #expect(NativeAgentProcessFocusRevalidator.classifyTerminalOwner(
            executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        ) == .terminal)
        #expect(NativeAgentProcessFocusRevalidator.classifyTerminalOwner(
            executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor"
        ) == .cursor)
        #expect(NativeAgentProcessFocusRevalidator.classifyTerminalOwner(
            executablePath: "/usr/local/bin/ghostty-helper"
        ) == nil)
        #expect(NativeAgentProcessFocusRevalidator.classifyTerminalOwner(
            executablePath: "/Users/example/.local/share/cursor-agent/versions/x/node"
        ) == nil)
    }

    @MainActor
    @Test("Controller revalidates the process again immediately before focus")
    func actionTimeProcessRevalidation() async {
        let boot = UUID()
        let identity = AgentProcessInstanceIdentity(
            hostBootID: boot,
            pid: 42,
            startedAtUnixNs: 123
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys004",
            terminalOwner: .terminal
        )
        let revalidator = SequencedRevalidator([
            .valid(live),
            .processIdentityChanged,
        ])
        let scripts = FocusScriptExecutor()
        let controller = MacAgentTUIFocusController(
            processRevalidator: revalidator,
            applicationQuery: TerminalOnlyApplicationQuery(),
            appleScript: scripts
        )
        let result = await controller.focus(makeSession(identity: identity))
        #expect(result == .unavailable(.processIdentityChanged))
        #expect(revalidator.callCount == 2)
        #expect(await scripts.callCount == 1) // enumeration only; focus was blocked
    }

    @MainActor
    @Test("Ghostty ownership never queries or enumerates Terminal")
    func ghosttyOwnershipRoutesOnlyToGhostty() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 43,
            startedAtUnixNs: 124
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys005",
            terminalOwner: .ghostty
        )
        let applications = RecordingApplicationQuery(running: [.ghostty, .terminal])
        let scripts = FocusScriptExecutor(results: [
            .failure(AgentAppleScriptExecutionFailure(
                number: -1728,
                message: "Ghostty 1.3 has no TTY property"
            )),
            .success(.list([
                .list([.text("ghost-1"), .text("/work")]),
            ])),
            .success(.missing),
        ])
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live), .valid(live)]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(makeSession(identity: identity))

        #expect(result == .focused(.ghostty(terminalID: "ghost-1")))
        #expect(applications.queriedApplications == [.ghostty, .ghostty])
        let sources = await scripts.sources
        #expect(sources.count == 3)
        #expect(sources.allSatisfy { $0.contains("com.mitchellh.ghostty") })
        #expect(sources.allSatisfy { !$0.contains("com.apple.Terminal") })
    }

    @MainActor
    @Test("Ghostty 1.4 ownership routes by exact TTY before CWD")
    func ghosttyTTYOwnershipRoute() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 46,
            startedAtUnixNs: 127
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/agent/work",
            tty: "/dev/ttys005",
            terminalOwner: .ghostty
        )
        let applications = RecordingApplicationQuery(running: [.ghostty])
        let scripts = FocusScriptExecutor(results: [
            .success(.list([
                .list([.text("ghost-tty"), .text("/dev/ttys005")]),
            ])),
            .success(.missing),
        ])
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live), .valid(live)]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(makeSession(identity: identity))

        #expect(result == .focused(.ghostty(terminalID: "ghost-tty")))
        #expect(applications.queriedApplications == [.ghostty, .ghostty])
        let sources = await scripts.sources
        #expect(sources.count == 2)
        #expect(sources[0].contains("«class Gtty»"))
        #expect(sources[1].contains("/dev/ttys005"))
        #expect(!sources[1].contains("working directory of candidateTerminal"))
    }

    @MainActor
    @Test("Ghostty 1.3 reports the missing identity bridge when CWD cannot prove a surface")
    func ghosttyLegacyIdentityUnavailable() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 47,
            startedAtUnixNs: 128
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/agent/work",
            tty: "/dev/ttys010",
            terminalOwner: .ghostty
        )
        let scripts = FocusScriptExecutor(results: [
            .failure(AgentAppleScriptExecutionFailure(
                number: -1728,
                message: "Ghostty 1.3 has no TTY property"
            )),
            .success(.list([
                .list([.text("unrelated"), .text("/different/work")]),
            ])),
        ])
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live)]),
            applicationQuery: RecordingApplicationQuery(running: [.ghostty]),
            appleScript: scripts
        )

        let result = await controller.focus(makeSession(identity: identity))

        #expect(result == .unavailable(.terminalIdentityUnavailable))
        #expect(await scripts.callCount == 2)
    }

    @MainActor
    @Test("Terminal ownership never queries or enumerates Ghostty")
    func terminalOwnershipRoutesOnlyToTerminal() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 44,
            startedAtUnixNs: 125
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys004",
            terminalOwner: .terminal
        )
        let applications = RecordingApplicationQuery(running: [.ghostty, .terminal])
        let scripts = FocusScriptExecutor(value: .list([
            .list([.integer(1), .integer(1), .text("/dev/ttys004")]),
        ]))
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live), .valid(live)]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(makeSession(identity: identity))

        #expect(result == .focused(.terminal(tty: "/dev/ttys004")))
        #expect(applications.queriedApplications == [.terminal, .terminal])
        let sources = await scripts.sources
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.contains("com.apple.Terminal") })
        #expect(sources.allSatisfy { !$0.contains("com.mitchellh.ghostty") })
    }

    @MainActor
    @Test("Unknown ownership uses TTY evidence against Ghostty when it is running")
    func unknownOwnershipUsesRunningGhosttyByTTY() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 45,
            startedAtUnixNs: 126
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys006",
            terminalOwner: .unknown
        )
        let applications = RecordingApplicationQuery(running: [.ghostty])
        let scripts = FocusScriptExecutor(value: .list([
            .list([.text("ghostty-term"), .text("/dev/ttys006")]),
        ]))
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live), .valid(live)]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(
            makeSession(identity: identity, provider: .cursor, tty: "/dev/ttys006")
        )

        #expect(result == .focused(.ghostty(terminalID: "ghostty-term")))
        #expect(applications.queriedApplications.contains(.ghostty))
        // Terminal may be probed for isRunning, but must not be scripted when absent.
        let sources = await scripts.sources
        #expect(sources.contains { $0.contains("com.mitchellh.ghostty") })
        #expect(sources.allSatisfy { !$0.contains("com.apple.Terminal") })
    }

    @MainActor
    @Test("Unknown ownership tries every running host by TTY for any provider")
    func unknownOwnershipTriesAllRunningHostsByTTY() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 46,
            startedAtUnixNs: 127
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys007",
            terminalOwner: .unknown
        )
        let applications = RecordingApplicationQuery(running: [.ghostty, .terminal])
        // Ghostty enumeration misses; Terminal enumeration matches.
        let scripts = FocusScriptExecutor(results: [
            .success(.list([])),
            .success(.list([
                .list([.integer(1), .integer(1), .text("/dev/ttys007")]),
            ])),
            .success(.text("ok")),
        ])
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([
                .valid(live),
                .valid(live),
                .valid(live),
            ]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(
            makeSession(identity: identity, provider: .claudeCode, tty: "/dev/ttys007")
        )

        #expect(result == .focused(.terminal(tty: "/dev/ttys007")))
        #expect(applications.queriedApplications.contains(.ghostty))
        #expect(applications.queriedApplications.contains(.terminal))
        let sources = await scripts.sources
        #expect(sources.contains { $0.contains("com.mitchellh.ghostty") })
        #expect(sources.contains { $0.contains("com.apple.Terminal") })
    }

    @MainActor
    @Test("Unknown ownership does not invent Terminal when no host is running")
    func unknownOwnershipDoesNotAssumeTerminal() async {
        let identity = AgentProcessInstanceIdentity(
            hostBootID: UUID(),
            pid: 45,
            startedAtUnixNs: 126
        )
        let live = RevalidatedAgentProcess(
            identity: identity,
            canonicalWorkingDirectory: "/work",
            tty: "/dev/ttys006",
            terminalOwner: .unknown
        )
        let applications = RecordingApplicationQuery(running: [])
        let scripts = FocusScriptExecutor(value: .missing)
        let controller = MacAgentTUIFocusController(
            processRevalidator: SequencedRevalidator([.valid(live)]),
            applicationQuery: applications,
            appleScript: scripts
        )

        let result = await controller.focus(
            makeSession(identity: identity, provider: .cursor, tty: "/dev/ttys006")
        )

        guard case let .failed(failure) = result else {
            Issue.record("Expected a failed result, got \(result)")
            return
        }
        #expect(failure.message.contains("Ghostty") || failure.message.contains("Terminal"))
        #expect(!failure.message.lowercased().contains("cursor is not running"))
        #expect(applications.queriedApplications == [.ghostty, .terminal])
        #expect(await scripts.sources.isEmpty)
    }

    private func makeSession(
        identity: AgentProcessInstanceIdentity,
        provider: AgentProvider = .codex,
        tty: String = "/dev/ttys004"
    ) -> AgentSessionSnapshot {
        let source = AgentSourceRevision(
            sourceEpoch: AgentObservationSourceEpoch(
                sourceID: AgentObservationSourceID()
            ),
            sequence: 1
        )
        let evidence = AgentEvidenceSet(confidence: .authoritative, items: [])
        let process = AgentProcessSnapshot(
            process: AgentProcessInstance(
                identity: identity,
                canonicalWorkingDirectory: "/work",
                tty: tty
            ),
            liveness: .live,
            livenessEvidence: evidence,
            sourceRevision: source
        )
        return AgentSessionSnapshot(
            identity: AgentProviderSessionIdentity(
                provider: provider,
                nativeSessionID: "session"
            ),
            displayLabel: nil,
            canonicalWorkingDirectory: "/work",
            canonicalWorktreeRoot: "/work",
            liveness: .live,
            execution: .idle,
            attentionDemand: .none,
            boundedUserPrompt: nil,
            boundedAssistantPreview: nil,
            processes: [process],
            identityEvidence: evidence,
            livenessEvidence: evidence,
            executionEvidence: evidence,
            attentionEvidence: evidence,
            sourceRevision: source,
            memoryRevision: AgentMemoryRevision(rawValue: 1)
        )
    }
}

private final class SequencedRevalidator: AgentProcessFocusRevalidating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [AgentProcessRevalidationResult]
    private var index = 0

    init(_ values: [AgentProcessRevalidationResult]) { self.values = values }

    var callCount: Int {
        lock.withLock { index }
    }

    func revalidate(_ process: AgentProcessInstance) -> AgentProcessRevalidationResult {
        lock.withLock {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}

private struct TerminalOnlyApplicationQuery: AgentTerminalApplicationQuerying {
    func isRunning(_ application: AgentTerminalApplication) -> Bool {
        application == .terminal
    }
}

private actor FocusScriptExecutor: AgentAppleScriptExecuting {
    private(set) var callCount = 0
    private(set) var sources: [String] = []
    private var results: [Result<AgentAppleScriptValue, AgentAppleScriptExecutionFailure>]

    init(value: AgentAppleScriptValue = .list([
        .list([.integer(1), .integer(1), .text("/dev/ttys004")]),
    ])) {
        results = [.success(value)]
    }

    init(results: [Result<AgentAppleScriptValue, AgentAppleScriptExecutionFailure>]) {
        precondition(!results.isEmpty)
        self.results = results
    }

    func execute(_ source: String) async throws -> AgentAppleScriptValue {
        callCount += 1
        sources.append(source)
        let result = results.count == 1 ? results[0] : results.removeFirst()
        return try result.get()
    }
}

private final class RecordingApplicationQuery: AgentTerminalApplicationQuerying,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let running: Set<AgentTerminalApplication>
    private var applications: [AgentTerminalApplication] = []

    init(running: Set<AgentTerminalApplication>) {
        self.running = running
    }

    var queriedApplications: [AgentTerminalApplication] {
        lock.withLock { applications }
    }

    func isRunning(_ application: AgentTerminalApplication) -> Bool {
        lock.withLock {
            applications.append(application)
            return running.contains(application)
        }
    }
}
