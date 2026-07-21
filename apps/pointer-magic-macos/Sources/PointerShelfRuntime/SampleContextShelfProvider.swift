import Foundation
import os
import PointerShelfContracts

/// Demo provider that proves the Gemini-style primary card + action pills layout.
///
/// It does not implement Calendar or mail — it only returns a declarative document
/// and reports invoke results.
public final class SampleContextShelfProvider: ShelfProviding, Sendable {
    public static let providerID = "sample.context"

    public let id = SampleContextShelfProvider.providerID
    public let priority = 40
    public let interests = ShelfProviderInterests.any

    private let revisionSeed = OSAllocatedUnfairLock(initialState: UInt64(1))

    public init() {}

    public func propose(packet: PointerContextPacket) async -> ShelfProposal {
        let chips = packet.snippets.prefix(2).map { snippet in
            ShelfContextChip(id: snippet.id, text: snippet.text, dismissible: true)
        }
        guard !chips.isEmpty || packet.hitTarget.title != nil || packet.appWindow.bundleIdentifier != nil
        else {
            return .decline
        }

        let revision = revisionSeed.withLock { value -> UInt64 in
            value &+= 1
            return value
        }

        let document = ShelfDocument(
            id: "sample-\(packet.revision)",
            providerId: id,
            revision: revision,
            contextRevision: packet.revision,
            primary: ShelfPrimaryCard(
                chips: chips.isEmpty
                    ? [
                        ShelfContextChip(
                            id: "fallback",
                            text: packet.hitTarget.title
                                ?? packet.hitTarget.selectedText
                                ?? packet.appWindow.windowTitle
                                ?? "On-screen context",
                            dismissible: true
                        ),
                      ]
                    : Array(chips),
                prompt: ShelfPromptSlot(placeholder: "Select anything to ask Pointer Magic"),
                accessories: [.expand, .dismiss]
            ),
            actions: [
                ShelfActionPill(
                    id: "view-schedule",
                    title: "View my schedule",
                    icon: .systemImage("calendar"),
                    rank: 0
                ),
                ShelfActionPill(
                    id: "draft-reply",
                    title: "Draft a reply",
                    icon: .systemImage("arrowshape.turn.up.left"),
                    rank: 1
                ),
                ShelfActionPill(
                    id: "suggest-places",
                    title: "Suggest meetup spots",
                    icon: .systemImage("mappin.and.ellipse"),
                    rank: 2
                ),
            ],
            fallback: nil
        )
        return .document(document)
    }

    public func invoke(
        actionId: String,
        packet: PointerContextPacket,
        grant: ShelfCapabilityGrant
    ) async -> ShelfActionResult {
        guard packet.authorizesActions else {
            return .denied("Context is not fresh enough")
        }
        guard grant.contextRevision == packet.revision else {
            return .denied("Stale context cannot authorize this action")
        }

        switch actionId {
        case "view-schedule":
            return .completed("Open Calendar for the captured date context")
        case "draft-reply":
            let snippet = packet.snippets.first?.text ?? packet.hitTarget.selectedText ?? ""
            if snippet.isEmpty {
                return .completed("Draft a reply")
            }
            return .completed("Draft a reply about “\(snippet.prefix(48))”")
        case "suggest-places":
            return .completed("Suggest meetup spots near the captured place context")
        default:
            return .unavailable("Unknown sample action")
        }
    }
}
