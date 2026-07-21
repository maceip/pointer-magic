# Pointer Magic Shelf Providers

Pointer Magic is the host. Developers ship **providers** that turn under-pointer
context into a declarative **shelf document**. Providers never draw AppKit or
inject arbitrary views.

## Concepts

| Piece | Owner | Role |
| --- | --- | --- |
| `PointerContextPacket` | Host | Budgeted AX + OCR + scene evidence at the pointer |
| `ShelfDocument` | Provider | Primary card, context chips, prompt, action pills |
| `ShelfProviding` | Provider | `propose` + `invoke` |
| Shelf renderer | Host | Glass chrome, park/follow, hit testing |

## Swift provider

```swift
import PointerShelfContracts
import PointerShelfRuntime

final class CalendarShelfProvider: ShelfProviding, @unchecked Sendable {
    let id = "example.calendar"
    let priority = 50
    let interests = ShelfProviderInterests(
        bundleIdentifierGlobs: ["com.apple.mail", "com.microsoft.Outlook"]
    )

    func propose(packet: PointerContextPacket) async -> ShelfProposal {
        guard let snippet = packet.snippets.first else { return .decline }
        return .document(
            ShelfDocument(
                id: "cal-\(packet.revision)",
                providerId: id,
                revision: packet.revision,
                contextRevision: packet.revision,
                primary: ShelfPrimaryCard(
                    chips: [ShelfContextChip(id: snippet.id, text: snippet.text)],
                    prompt: ShelfPromptSlot(placeholder: "Select anything to ask…")
                ),
                actions: [
                    ShelfActionPill(
                        id: "view-schedule",
                        title: "View my schedule",
                        icon: .systemImage("calendar")
                    ),
                ]
            )
        )
    }

    func invoke(
        actionId: String,
        packet: PointerContextPacket,
        grant: ShelfCapabilityGrant
    ) async -> ShelfActionResult {
        guard packet.authorizesActions,
              grant.contextRevision == packet.revision
        else {
            return .denied("Stale context")
        }
        guard actionId == "view-schedule" else {
            return .unavailable("Unknown action")
        }
        // Open Calendar, call your agent, etc. Pointer Magic does not implement this.
        return .completed("Opened schedule")
    }
}
```

Register in-process (current v1 surface):

```swift
await runtime.register(CalendarShelfProvider())
```

## JSON shape (XPC / remote later)

`ShelfDocument` and `PointerContextPacket` are `Codable`. The same schema is the
wire format for a future XPC or HTTP transport. A TypeScript SDK can emit JSON
documents; it still does not draw the shelf.

Minimal document:

```json
{
  "schemaVersion": 1,
  "id": "cal-42",
  "providerId": "example.calendar",
  "revision": 42,
  "contextRevision": 42,
  "ttlMs": 8000,
  "primary": {
    "chips": [{ "id": "s0", "text": "I'm in town on May 19.", "dismissible": true }],
    "prompt": { "placeholder": "Select anything to ask…" },
    "accessories": ["expand", "dismiss"]
  },
  "actions": [
    {
      "id": "view-schedule",
      "title": "View my schedule",
      "icon": { "systemImage": "calendar" },
      "enabled": true,
      "rank": 0
    }
  ]
}
```

## Host guarantees

- Propose is budgeted and cancelable; pointer motion never waits on providers.
- Park freezes the context revision used for `invoke`.
- Stale / partial packets set `freshness`; only `.current` authorizes actions.
- Icons are SF Symbols or pre-registered assets — no custom drawing callbacks.
- Secure AX targets redact text values before the packet is published.

## Built-in providers

- `agent` — compact agent pill (provider mark, directory, state)
- `sample.context` — Gemini-style demo card with schedule / draft / places actions

## Packages

- `PointerShelfContracts` — packet + document schemas
- `PointerShelfRuntime` — assembler, provider protocol, merge/invoke runtime
- `PointerAgentShelf` — park/follow renderer for `ShelfDocument`
