# Magic Pointer

This repository contains the complete Magic Pointer work: the product research,
interactive browser experiments, native macOS pointer foundation, proactive scene
discovery, and revisioned scene memory.

## Repository map

- `apps/showcase/` — local interactive browser research. The main page contains
  five Magic Pointer experiments; `/after-chat` preserves the earlier Intent Halo,
  Shadow Run, and Apprentice Relay study.
- `apps/magic-pointer-macos/` — the native Swift package and app. macOS continues
  to draw the real cursor; Magic Pointer observes it and draws separate companion
  windows.
- `docs/REPORT.md` — the Magic Pointer product assessment and five experiments.
- `docs/research.md` — the earlier browser-agent research.
- `docs/research-screens/` — the supplied Google mock and real-demo references.

## Run the local showcase

```bash
cd apps/showcase
npm install
npm run dev
```

Open `http://127.0.0.1:5173`. The showcase has no sign-in, external hosting
configuration, or third-party authentication dependency.

## Run the native app

```bash
cd apps/magic-pointer-macos
swift run MagicPointer
```

To assemble the app bundle instead:

```bash
cd apps/magic-pointer-macos
./scripts/build-app.sh --open
```

The native implementation is deliberately layered:

1. Passive pointer capture and bounded event transport.
2. Accessibility semantics and a click-through liquid-glass companion.
3. Shake activation, the physical Right Option clutch, and a non-key interactive panel.
4. Settled-pointer text and image perception.
5. Proactive workspace, Accessibility, and dirty-region scene discovery.
6. Identity, revision, invalidation, coverage, refresh, and transport contracts.
7. Revisioned in-memory scene storage and bounded cache-first pointer queries.

The transport contracts include a seam for a future authenticated network source,
but this repository does not contain or start a network client, listener, or remote
runtime.
