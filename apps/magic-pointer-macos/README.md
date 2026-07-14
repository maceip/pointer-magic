# Magic Pointer native bedrock

This package is the local macOS foundation beside the browser experiments in
`../showcase`. macOS continues to own and draw the real cursor. Magic Pointer
observes primitive pointer state, resolves accessibility semantics separately,
and draws a nonactivating, click-through companion in transparent AppKit panels.

The cursor glyph and hotspot are a protected visual area. The renderer places its
companion cluster in the first free adjacent quadrant and will not draw a ring,
dot, label, or orbiting item over the cursor itself.

The resting state is invisible: only the native cursor is present. A deliberate
shake activates a compact companion close and directly below the cursor. It flips
above near the bottom edge; lateral placement is only a final fallback.

Holding the physical Right Option key is a clutch. It replaces the click-through
follower with an exact-size interactive panel at the same location. Moving the
pointer into that fixed panel latches it; releasing Option before entry returns to
following. The panel is a separate window, so the full-screen overlay never changes
from passive to interactive.

On macOS 26 the sidecar uses the public `NSGlassEffectView`; macOS 14–15 use a
public `NSVisualEffectView` fallback. Both the follower and pinned panel remain
neutral liquid glass; an opaque adaptive surface is used only when Reduce
Transparency or Increase Contrast requires it.

There is no browser runtime, remote model, network request, authentication provider,
cursor replacement, cursor warp, synthetic input, or action from hover in this layer.
While Magic Pointer is on, a separate local perception lane analyzes a bounded
480×320-point screen crop after the pointer settles. Screen pixels, OCR text, and
image classifications remain in memory; explicit feedback stores only object IDs,
kinds, bounds, provenance labels, and evidence-source names. Turning Magic Pointer
off stops event capture, semantic lookup, local screen analysis, and every overlay.
The capped local feedback log is `~/Library/Application Support/Magic Pointer/perception-feedback.jsonl`.
This settled-pointer lane does not feed the background scene cache. That cache
currently ingests only workspace metadata, structural Accessibility metadata, and
ScreenCaptureKit dirty-rectangle metadata—not pixels, OCR, Vision results, or
settled-pointer perception output.

## Why the reference packages are not runtime dependencies

The useful EventTapper boundary was reimplemented directly because its high-level
path creates an `NSEvent` for every `CGEvent`, exposes event suppression/posting,
and attaches to whichever run loop creates it. The owned tap is always a passive
`.listenOnly` session tap on a dedicated run loop and copies only fixed primitive
fields.

AXorcist remains a useful reference for richer future automation, but version
0.1.2 puts synchronous point queries on `MainActor` and resolves packages unrelated
to hit testing. The owned AX adapter is serial, bounded, coalescing, time-limited,
and never returns a raw `AXUIElement` to a client.

## Runtime lanes

```text
CGEventTap thread
  -> atomic latest-motion mailbox (movement may be coalesced)
  -> fixed 128-event SPSC ring (buttons + physical Right Option stay ordered)

NSScreen CADisplayLink / MainActor
  -> read newest movement and drain discrete input once per display frame
  -> merge both lanes by the tap's monotonic event sequence
  -> move CALayers in a click-through NSPanel
  -> synchronously notify constant-time gesture owners without a reorder buffer
  -> publish independent PointerFrame and discrete observer streams

dedicated AX OperationQueue
  -> at most one running and one replaceable pending request
  -> immutable, schema-versioned SemanticSnapshot
  -> session-scoped target IDs for explicit later actions

background scene discovery (never on a pointer callback)
  -> workspace/window census plus shallow, bounded Accessibility scans
  -> low-rate ScreenCaptureKit dirty-rectangle stream when permission already exists
  -> receiver-authorized, atomic event batches
  -> revisioned scene memory and an immutable spatial read snapshot

pointer cache probe API (not yet consumed by the current interaction UI)
  -> exact current desktop coordinate-space revision
  -> fixed multiresolution index; at most 544 candidates examined
  -> immediate geometry, followed by bounded asynchronous field hydration
  -> stale and partial states are marked in result metadata and never authorize an action
```

No platform or third-party object crosses the public interface. Higher layers use
`PointerBedrockInterface` with `PointerFrame`, `SemanticRequest`,
`SemanticSnapshot`, `OverlayScene`, and `SemanticActionRequest` values from
`MagicPointerCore`.

Motion, discrete input, accessibility, and rendering have independent rates. An
unresponsive accessibility client therefore cannot delay the real cursor or the
Halo. Gesture owners that need cross-lane ordering use `observeOrderedInput`; ordinary
observers can keep using the independently buffered frame and discrete streams.
If the discrete ring ever overflows, the interaction lane immediately cancels active
gesture state, quarantines both lanes until the ring is observed empty, and reconciles
only the newest pointer frame without treating it as a gesture sample.

## Background observation and scene memory

Scene discovery is a separate local subsystem, not an extension of pointer capture.
It registers three independent sources: public workspace/window metadata, a shallow
Accessibility census, and ScreenCaptureKit dirty-region metadata. The
Accessibility source reacts to notifications and also performs a bounded periodic
reconciliation so useful context can already be in memory before the pointer arrives.
The dirty-region source registers and publishes an empty checkpoint plus an explicit
permission gap even without Screen Recording permission. Only its capture stream is
gated by `CGPreflightScreenCaptureAccess()`. When active, its callback copies bounded
frame-attachment rectangles and never reads or retains sample-buffer image data.

Producers assign source-local object IDs within their own epoch. The receiver owns
authorization and canonical cache IDs: its opaque grant controls fields, evidence
types, surfaces, and cross-source dependencies, and accepted events are reduced
atomically into bounded memory. A source restart retires its old epoch, and display
geometry is accepted only in the exact coordinate-space revision in which it was
observed. Public CoreGraphics metadata cannot reveal a `CGWindowID` that was reused
between two uninterrupted censuses, and this implementation does not use private APIs
to infer that boundary.

Coverage is explicit rather than assumed. Checkpoints establish a baseline; heartbeats
extend its lease only while continuity remains intact; sequence loss, lease expiry,
permission loss, backpressure, and source shutdown break it. After a break or expired
lease, a new checkpoint is required before continuity can be re-established. All three
current local producers report best-effort coverage, so their cached fields can be at
most provisional. Only a future complete-event producer could yield `verifiedCurrent`.

The synchronous pointer-side read is an immutable snapshot behind a short lock. Its
spatial index has fixed fanout and a hard examination ceiling independent of total
object count. Older results may be returned as a clearly stale first paint according
to field-specific reuse windows. Missing, expired, truncated, and dropped candidates
are reported rather than hidden. Hydration happens later through the actor-owned store.
Scene memory is process- and session-local: it has no disk persistence or relaunch
restore. Ordinary claims may carry values; claims classified secure or sensitivity
unknown are value-less. Privacy invalidation or reclassification also purges retained
values and replay envelopes that could contain an earlier ordinary value.

`SceneEventBatchChannel` is the transport-neutral seam for a future phone or remote
observer. It deliberately defines only manifest, batch, receipt, and backpressure
semantics. There is no network client, listener, authentication flow, or remote runtime
in this package. A future host adapter must authenticate its peer and mint the local
opaque grant; handles and grants never travel over that channel.

Scene memory is context, never action authority. Any later side effect must perform a
fresh live Accessibility hit test and revalidate its short-lived action permission.

## Build and test

```bash
cd apps/magic-pointer-macos
swift test
swift run -c release MagicPointerBench
./scripts/build-app.sh --open
```

The app is assembled at `.build/app/Magic Pointer.app` and ad-hoc signed by
default. For a stable TCC identity across rebuilds, set a real local signing
identity:

```bash
MAGIC_POINTER_CODESIGN_IDENTITY="Apple Development: …" \
  ./scripts/build-app.sh --open
```

The app requests missing Input Monitoring, Accessibility, and Screen Recording
permissions only when you choose **Request Next Permission…** from the menu. macOS
handles one permission at a time; use the command again after enabling each one.
Input Monitoring covers pointer events and
only the physical Right Option modifier used by the clutch; typed text and other
keys are not collected. Screen Recording supplies the bounded local crop used for
OCR and image classification in the separate settled-pointer perception lane; those
results do not enter background scene memory. Without Input Monitoring, the app
exposes an honest manual activation fallback but cannot advertise shake or the
global clutch. Without Accessibility, visual analysis stays disabled rather than
risking capture of a secure or sensitivity-unknown target. Without Screen Recording,
the lens reports Accessibility evidence only.

The position-only fallback is read-only. Future explicit AX actions require the
event-tap mode and re-check the physical Quartz cursor immediately before the
side effect; a stale generation or moved cursor is rejected.

## Public interaction example

```swift
import MagicPointerKit
import PointerCore

@MainActor
func attachFeature(to pointer: PointerBedrock) async {
    for await frame in pointer.frames() {
        // Frames arrive at display cadence; slow consumers cannot back up motion.
        let request = SemanticRequest(
            generation: frame.generation,
            point: frame.coordinates.quartzGlobal,
            requestedAtNs: frame.publishedTimestampNs
        )
        let context = await pointer.resolve(request)
        guard let target = context.target else { continue }

        let now = DispatchTime.now().uptimeNanoseconds
        try? pointer.present(
            OverlayScene(
                sourceID: "threadline",
                generation: frame.generation,
                createdAtNs: now,
                expiresAtNs: now + 500_000_000,
                anchor: frame.coordinates.quartzGlobal,
                targetFrame: target.frame,
                title: target.label,
                items: []
            )
        )
    }
}
```

Production feature code should request semantics deliberately or through a settled
pointer policy; it should not resolve every emitted frame as this compact API
example does.

## Measured gates

- Event-tap callback p99 target: at most 100 µs; maximum target: 500 µs.
- Event-to-layer commit p95: at most 12 ms on 120 Hz, 20 ms on 60 Hz.
- Fresh AX p95 target: 45 ms with a 60 ms request deadline.
- Lost button transitions: zero; overflow is a visible health fault.
- Pointer mode off: no tap, no display link, no overlay.
- Full-screen overlay windows can never become key/main and always ignore mouse
  events; the exact-size pinned panel is the only interactive surface.

`MagicPointerBench` guards the atomic mailbox against transport regressions. The
menu reports live callback and render latency. Before a release, the remaining
physical gates are a long real-mouse soak, mixed-display/Spaces testing, and a
high-speed-camera cursor-to-Halo measurement.
