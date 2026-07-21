import Foundation
import PointerShelfContracts
import PointerShelfRuntime
import Testing

@Suite("Shelf enrichment mailbox")
struct ShelfEnrichmentMailboxTests {
    @Test("Begin attempt supersedes prior generations")
    func beginSupersedes() {
        var mailbox = ShelfEnrichmentMailbox()
        let first = mailbox.beginAttempt()
        let second = mailbox.beginAttempt()
        #expect(first != second)
        #expect(!mailbox.isCurrent(first))
        #expect(mailbox.isCurrent(second))
    }

    @Test("Stale attempts cannot commit")
    func staleDropped() {
        var mailbox = ShelfEnrichmentMailbox()
        let stale = mailbox.beginAttempt()
        _ = mailbox.beginAttempt()
        let document = ShelfDocument.compact(
            id: "a",
            providerId: "agent",
            revision: 1,
            provider: "Codex",
            state: "Working"
        )
        #expect(mailbox.commitIfCurrent(attempt: stale, document: document) == nil)
    }

    @Test("Current attempt commits non-empty documents")
    func currentCommits() {
        var mailbox = ShelfEnrichmentMailbox()
        let attempt = mailbox.beginAttempt()
        let document = ShelfDocument(
            id: "sample-1",
            providerId: "sample.context",
            revision: 1,
            primary: ShelfPrimaryCard(
                chips: [ShelfContextChip(id: "c", text: "Hello")],
                prompt: ShelfPromptSlot(placeholder: "Ask")
            ),
            actions: [
                ShelfActionPill(
                    id: "view-schedule",
                    title: "View my schedule",
                    icon: .systemImage("calendar")
                ),
            ]
        )
        #expect(mailbox.commitIfCurrent(attempt: attempt, document: document) == document)
        #expect(
            mailbox.commitIfCurrent(
                attempt: attempt,
                document: ShelfDocument.compact(
                    id: "",
                    providerId: "agent",
                    revision: 1,
                    provider: "",
                    state: ""
                )
            ) == nil
        )
    }
}
