@preconcurrency import AppKit
@testable import PointerAgentShelf
import PointerShelfContracts
import Testing

@Suite("Shelf session coordinator")
@MainActor
struct ShelfSessionCoordinatorTests {
    @Test("Park freezes the followed identity until release")
    func parkAndRelease() {
        let coordinator = ShelfSessionCoordinator()
        let identity = ShelfItemIdentity("demo:1")
        let presentation = AgentShelfPresentation(
            provider: "Demo",
            state: "Working",
            directoryName: "repo"
        ).asShelfDocument(id: identity.rawValue)
        coordinator.isEnabled = { true }
        coordinator.isFocusInFlight = { false }
        coordinator.parkTargetProvider = { (identity, presentation) }

        coordinator.applyUpdate(identity: identity, presentation: presentation)
        #expect(coordinator.phase == .following(identity))
        #expect(coordinator.tryPark())
        #expect(coordinator.phase == .parked(identity))
        #expect(coordinator.controller.isLockedForInteraction)

        #expect(coordinator.releasePark())
        #expect(coordinator.phase == .following(identity))
        #expect(!coordinator.controller.isLockedForInteraction)
        coordinator.stop()
    }

    @Test("Failed focus keeps the shelf parked for retry")
    func failedFocusKeepsPark() {
        let coordinator = ShelfSessionCoordinator()
        let identity = ShelfItemIdentity("demo:focus")
        let presentation = AgentShelfPresentation(
            provider: "Demo",
            state: "Working",
            directoryName: "repo"
        ).asShelfDocument(id: identity.rawValue)
        coordinator.isEnabled = { true }
        coordinator.isFocusInFlight = { false }
        coordinator.parkTargetProvider = { (identity, presentation) }

        coordinator.applyUpdate(identity: identity, presentation: presentation)
        #expect(coordinator.tryPark())
        #expect(coordinator.beginFocus() == identity)
        #expect(coordinator.phase == .focusing(identity))
        coordinator.cancelFocusKeepParked(status: "Could not find this agent's terminal")
        #expect(coordinator.phase == .parked(identity))
        #expect(coordinator.controller.isLockedForInteraction)
        coordinator.stop()
    }

    @Test("Dismiss keeps the exact identity and state hidden")
    func dismissKey() {
        let coordinator = ShelfSessionCoordinator()
        let identity = ShelfItemIdentity("demo:2")
        let presentation = AgentShelfPresentation(
            provider: "Demo",
            state: "Working",
            directoryName: "repo"
        ).asShelfDocument(id: identity.rawValue)
        coordinator.isEnabled = { true }
        coordinator.isFocusInFlight = { false }
        coordinator.parkTargetProvider = { (identity, presentation) }

        coordinator.applyUpdate(identity: identity, presentation: presentation)
        #expect(coordinator.tryPark())
        coordinator.dismissParked()
        #expect(coordinator.phase == .dismissed(
            ShelfDismissKey(identity: identity, state: "compact:Working")
        ))
        #expect(!coordinator.controller.isVisible)

        coordinator.applyUpdate(identity: identity, presentation: presentation)
        #expect(!coordinator.controller.isVisible)

        let next = AgentShelfPresentation(
            provider: "Demo",
            state: "Done",
            directoryName: "repo"
        ).asShelfDocument(id: identity.rawValue)
        coordinator.applyUpdate(identity: identity, presentation: next)
        #expect(coordinator.controller.isVisible)
        #expect(coordinator.phase == .following(identity))
        coordinator.stop()
    }

    @Test(
        "Enrichment commits passively and does not retarget sticky identity",
        arguments: [
            ("Codex", AgentShelfProviderMark.codex),
            ("Claude", AgentShelfProviderMark.claude),
        ]
    )
    func enrichmentPassive(provider: String, mark: AgentShelfProviderMark) {
        let coordinator = ShelfSessionCoordinator()
        let identity = ShelfItemIdentity("\(mark.rawValue)\u{1f}agent-1")
        let compact = AgentShelfPresentation(
            provider: provider,
            state: "Working",
            directoryName: "repo",
            providerMark: mark
        ).asShelfDocument(id: identity.rawValue)
        coordinator.isEnabled = { true }
        coordinator.isFocusInFlight = { false }
        coordinator.parkTargetProvider = { (identity, compact) }
        coordinator.applyUpdate(identity: identity, presentation: compact)
        #expect(coordinator.stickyIdentity == identity)
        #expect(coordinator.lastPresentation?.fallback?.provider == provider)
        #expect(coordinator.lastPresentation?.fallback?.providerMark == mark.rawValue)

        let enriched = ShelfDocument(
            id: "sample-9",
            providerId: "sample.context",
            revision: 9,
            primary: ShelfPrimaryCard(
                chips: [ShelfContextChip(id: "c", text: "I'm in town")],
                prompt: ShelfPromptSlot(placeholder: "Ask")
            ),
            actions: [
                ShelfActionPill(
                    id: "draft-reply",
                    title: "Draft a reply",
                    icon: .systemImage("arrowshape.turn.up.left")
                ),
            ]
        )
        coordinator.applyEnrichment(
            identity: ShelfItemIdentity(enriched.id),
            presentation: enriched
        )
        #expect(coordinator.stickyIdentity == identity)
        #expect(coordinator.lastPresentation == enriched)
        #expect(coordinator.phase == .following(identity))

        #expect(coordinator.tryPark())
        let whileParked = ShelfDocument(
            id: "sample-10",
            providerId: "sample.context",
            revision: 10,
            primary: ShelfPrimaryCard(
                chips: [ShelfContextChip(id: "c", text: "Later")]
            )
        )
        coordinator.applyEnrichment(identity: identity, presentation: whileParked)
        #expect(coordinator.lastPresentation == enriched)
        coordinator.stop()
    }
}
