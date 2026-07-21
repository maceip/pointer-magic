import Foundation
@testable import PointerAgentShelf
import Testing

@Suite("Agent shelf presentation")
struct AgentShelfPresentationTests {
    @Test("Input is single-line and unshortened")
    func contentIsPreserved() {
        let fullState = Array(repeating: "working", count: 20).joined(separator: " ")
        let fullDirectory = "a-very-long-directory-name-that-must-survive-the-presentation-model-without-an-ellipsis"
        let presentation = AgentShelfPresentation(
            provider: "  Codex\nDesktop  ",
            state: fullState,
            directoryName: fullDirectory
        )

        #expect(presentation.provider == "Codex Desktop")
        #expect(presentation.state == fullState)
        #expect(presentation.directoryName == fullDirectory)
    }

    @Test("Empty provider and state yield an empty presentation")
    func emptyPresentation() {
        #expect(
            AgentShelfPresentation(
                provider: "",
                state: "",
                directoryName: ""
            ).isEmpty
        )
        #expect(
            !AgentShelfPresentation(
                provider: "Codex",
                state: "",
                directoryName: ""
            ).isEmpty
        )
    }

    @Test("Presentation contract is only the painted compact fields")
    func paintedFieldsOnly() {
        let presentation = AgentShelfPresentation(
            provider: "Codex",
            state: "Working",
            directoryName: "webagent-ui",
            providerMark: .codex
        )
        #expect(presentation.providerMark == .codex)
        #expect(presentation.directoryName == "webagent-ui")
        #expect(presentation.state == "Working")
    }

    @Test(
        "Provider marks resolve for Codex and Claude labels",
        arguments: [
            ("Codex", AgentShelfProviderMark.codex),
            ("Codex Desktop", AgentShelfProviderMark.codex),
            ("Claude", AgentShelfProviderMark.claude),
            ("Claude Code", AgentShelfProviderMark.claude),
            ("anthropic", AgentShelfProviderMark.claude),
        ]
    )
    func providerMarksResolve(provider: String, expected: AgentShelfProviderMark) {
        let presentation = AgentShelfPresentation(
            provider: provider,
            state: "Working",
            directoryName: "repo"
        )
        #expect(presentation.providerMark == expected)
        #expect(AgentShelfProviderMark(providerName: provider) == expected)
    }

    @Test("Shelf item identity is opaque and stable")
    func shelfItemIdentity() {
        let a = ShelfItemIdentity("codex\u{1f}abc")
        let b = ShelfItemIdentity("codex\u{1f}abc")
        let c = ShelfItemIdentity("cursor\u{1f}abc")
        #expect(a == b)
        #expect(a != c)
        #expect(
            ShelfDismissKey(identity: a, state: "Working") ==
                ShelfDismissKey(identity: b, state: "Working")
        )
        #expect(
            ShelfDismissKey(identity: a, state: "Working") !=
                ShelfDismissKey(identity: a, state: "Done")
        )
    }
}
