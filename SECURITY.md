# Security

Pointer Magic is a local macOS companion. It does not ship a network client,
remote runtime, or cloud authentication path.

## Permissions

The app may request:

- **Input Monitoring** — passive `CGEventTap` for pointer motion / shake (listen-only; no event posting).
- **Accessibility** — hit-testing and structural semantics under the pointer.
- **Screen Recording** — bounded settled-pointer crops for OCR / image classification; crops stay in memory on this Mac.
- **Automation (Apple Events)** — only after an explicit parked-shelf click, to focus Ghostty, Terminal, or Cursor for the selected agent session.

Permission prompts are user-initiated via **Request Next Permission…** in the menu.

## What Pointer Magic does not do

- Replace, warp, or hide the system cursor
- Post synthetic keyboard or mouse events
- Steal focus in the background
- Send screen pixels, OCR text, or transcripts over a network from this package

## Local data

- Perception feedback (IDs / kinds / bounds only): `~/Library/Application Support/Pointer Magic/perception-feedback.jsonl`
- Agent transcript discovery reads existing local Codex / Claude / Cursor session files under the user’s home directory; it does not upload them

## Reporting issues

Open a GitHub issue with steps to reproduce. Do not attach screen recordings that contain secrets.
