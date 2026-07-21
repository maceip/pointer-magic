# Pointer Magic Product Hypothesis

The architectural description—“the mouse is a human-controlled context and routing
layer”—is not itself a product. The product is a much more specific feedback loop.

## Primary product hypothesis

> When a developer using multiple coding agents inspects an agent’s work in a
> running application and finds something wrong, holding Right Option over the
> defect should produce a complete correction packet—exact object, current visual
> state, build, repository, worktree, originating agent, relevant diff, runtime
> evidence, and the developer’s spoken instruction—and deliver it to the
> responsible agent for correction and subsequent verification.

The specific user story is:

1. An implementation agent says it finished.
2. The developer opens the localhost or deployed application.
3. They see that a button, animation, layout, or interaction is still wrong.
4. They point at it and hold Right Option.
5. Pointer Magic shows:

   ```text
   Chrome · localhost:5173 · toolbar button
   Build f528de3 · pointer-magic/main
   Changed by Agent “pointer-layout” · 6 minutes ago
   Related: 1 diff · 1 console warning · tester has not verified
   ```

6. The developer says: “Still too far right. Put it directly below this label.”
7. They choose **Send to owner**.
8. The implementation agent receives the target, screenshot, DOM/AX object,
   runtime state, build provenance, original objective, and correction.
9. After rebuilding, the testing agent checks the same identified object against
   the correction.

The product is not “information around your cursor.” It is:

> The shortest possible path from noticing an agent’s mistake to the correct
> agent understanding, fixing, and verifying it.

## Why the mouse matters

Today the developer manually performs several transfers:

- Find the correct agent session.
- Explain which application and build they inspected.
- Describe or screenshot the defective object.
- Paste console or terminal evidence.
- Restate the original objective.
- Determine which branch or worktree produced it.
- Tell another agent how to verify the correction.

The pointer provides the missing referent. The background system supplies
everything connected to it. The developer’s voice or prompt supplies the desired
change.

A screenshot alone has appearance but no provenance. An agent transcript has
provenance but cannot see what the developer just inspected. The pointer joins
those two worlds.

## First supported product boundary

The first real version should be intentionally narrow:

- macOS.
- Chrome or Chromium displaying a localhost web application.
- Codex and Claude Code sessions.
- Local Git repositories and worktrees.
- DOM objects, browser console errors, and terminal failures.
- One implementation agent and one verification agent.
- Explicit Right Option activation.
- No passive suggestions, phone client, arbitrary image understanding, or
  automatic edits.

That gives us one complete, deeply instrumented workflow instead of shallow
coverage everywhere.

## Four testable hypotheses

| Hypothesis | Exact interaction | What would prove it |
| --- | --- | --- |
| **1. Correction loop** | Point at defective live UI → speak correction → send to originating agent → verify the same object after rebuilding. | The agent can act without asking which object, build, file, or behavior the developer meant. |
| **2. Cross-agent handoff** | Point at a research result, test failure, or reviewer finding → choose an implementation agent. | The destination receives the source evidence, objective, constraints, files, and unresolved questions without manual copying. |
| **3. Acceptance contract** | Point at a reference state, then the current object, and describe the required difference. | A testing agent can evaluate subsequent builds against the same objects and requirement. |
| **4. Provenance and scope guard** | Point at a running object, file, terminal, or build and see its owning repo, worktree, revision, process, and agent. | It prevents work from being routed to the wrong project, directory, revision, or agent. |

## The correction packet

A useful packet is structured, not a giant generated explanation:

```text
Instruction
  “Move this directly below the heading.”

Target
  Chrome tab: http://localhost:5173
  DOM: button[data-action="continue"]
  Bounds: x=842 y=611 w=124 h=36
  Screenshot: bounded target plus nearby heading
  Observed revision: 14:32:08.441

Runtime
  Build: f528de3
  Console: one related warning
  Network: no failed requests
  Interaction: pointer entered, click produced no navigation

Provenance
  Repository: pointer-magic
  Worktree: ~/src/pointer-magic
  Branch: main
  Last relevant diff: PointerMagicInteractionController
  Owning objective: “move the companion below and closer”
  Implementing agent: pointer-layout
  Tester: browser-verifier

Destination
  Send correction to pointer-layout
  Ask browser-verifier to recheck after next build
```

Observed values should come directly from instrumentation. Generated
interpretation is optional enrichment, not the packet’s foundation.

## Success criteria

The initial experiment should measure:

- Correct object identified.
- Correct build, repository, worktree, and agent shown.
- Time from noticing the problem to delivering the correction.
- Whether the developer had to attach a screenshot manually.
- Whether they had to paste logs or find another session.
- Whether the agent needed a clarification turn.
- Whether the verifier checked the same object after rebuilding.
- Whether the developer voluntarily uses it again for the next defect.

The strongest outcome is not “the card looked intelligent.” It is:

> The developer pointed, spoke one sentence, and the correct agent immediately
> understood everything required to continue.

## What is secondary

These are extensions after that loop works:

- Pointing at terminal failures and routing them to the originating agent.
- Sending research or review results between agents.
- Recovering objectives after a crash.
- Comparing current and previous builds.
- Diagnosing development-machine processes.
- Remote phone or glasses feedback.
- Collecting several objects into a context tray.

The first product hypothesis is narrower: **close the visual feedback loop between
a human inspecting agent work and the agents responsible for correcting and
verifying it.**
