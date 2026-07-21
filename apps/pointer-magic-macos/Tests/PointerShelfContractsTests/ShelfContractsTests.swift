import Foundation
import PointerCore
import PointerShelfContracts
import Testing

@Suite("Shelf contracts")
struct ShelfContractsTests {
    @Test("Context packet caps snippets and authorizes only current freshness")
    func packetBudgetAndAuthority() {
        let long = String(repeating: "a", count: 400)
        let snippets = (0..<12).map { index in
            PointerContextSnippet(
                id: "s\(index)",
                text: long,
                provenance: .ocr
            )
        }
        let packet = PointerContextPacket(
            revision: 3,
            generation: 1,
            sequence: 2,
            assembledAtNs: 10,
            point: GlobalPoint(x: 1, y: 2),
            freshness: .current,
            snippets: snippets
        )
        #expect(packet.snippets.count == PointerContextPacket.maximumSnippetCount)
        #expect(packet.snippets.allSatisfy {
            $0.text.count == PointerContextPacket.maximumSnippetCharacters
        })
        #expect(packet.authorizesActions)

        let stale = PointerContextPacket(
            revision: 4,
            generation: 1,
            sequence: 3,
            assembledAtNs: 11,
            point: GlobalPoint(x: 1, y: 2),
            freshness: .stale
        )
        #expect(!stale.authorizesActions)
    }

    @Test("Shelf document sorts and caps actions")
    func documentActionCap() {
        let actions = (0..<8).map { index in
            ShelfActionPill(
                id: "a\(index)",
                title: "Action \(index)",
                icon: .systemImage("star"),
                rank: 8 - index
            )
        }
        let document = ShelfDocument(
            id: "doc",
            providerId: "sample",
            revision: 1,
            primary: ShelfPrimaryCard(
                chips: [ShelfContextChip(id: "c", text: "Hello")],
                prompt: ShelfPromptSlot(placeholder: "Ask")
            ),
            actions: actions
        )
        #expect(document.actions.count == ShelfDocument.maximumVisibleActions)
        #expect(document.actions.first?.id == "a7")
        #expect(document.usesExpandedLayout)
        #expect(!document.dismissFingerprint.isEmpty)
    }

    @Test("Compact document maps round-trip fields")
    func compactDocument() {
        let document = ShelfDocument.compact(
            id: "agent-1",
            providerId: "agent",
            revision: 9,
            provider: "Codex",
            state: "Working",
            directoryName: "webagent-ui",
            providerMark: "codex"
        )
        #expect(!document.usesExpandedLayout)
        #expect(document.fallback?.provider == "Codex")
        #expect(document.dismissFingerprint == "compact:Working")
    }

    @Test("Provider interests match bundle globs")
    func interests() {
        let interests = ShelfProviderInterests(bundleIdentifierGlobs: ["com.apple.*"])
        let mail = PointerContextPacket(
            revision: 1,
            generation: 1,
            sequence: 1,
            assembledAtNs: 1,
            point: GlobalPoint(x: 0, y: 0),
            freshness: .current,
            appWindow: PointerContextAppWindow(bundleIdentifier: "com.apple.mail")
        )
        let other = PointerContextPacket(
            revision: 1,
            generation: 1,
            sequence: 1,
            assembledAtNs: 1,
            point: GlobalPoint(x: 0, y: 0),
            freshness: .current,
            appWindow: PointerContextAppWindow(bundleIdentifier: "com.google.Chrome")
        )
        #expect(interests.matches(mail))
        #expect(!interests.matches(other))
        #expect(ShelfProviderInterests.any.matches(other))
    }
}
