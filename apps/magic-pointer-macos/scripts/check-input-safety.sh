#!/bin/zsh
# HARD INVARIANT GUARD: halo must NEVER take custody of user input.
# A listen-only tap can't consume events; a non-key panel can't receive
# keystrokes; no synthetic input is ever posted. If any of these regress, the
# app could block typing — which is fatal. Fail the build loud.
#
# Run: zsh scripts/check-input-safety.sh   (wire into CI / pre-commit)
set -euo pipefail
ROOT=${0:A:h:h}
SRC="$ROOT/Sources"
fail=0

flag() { echo "INPUT-SAFETY VIOLATION: $1"; fail=1; }

# 1. Event tap must be listen-only, never an active (consuming) tap.
if grep -rn "options:[[:space:]]*\.defaultTap" "$SRC" >/dev/null 2>&1; then
  flag "active .defaultTap event tap (must be .listenOnly)"
fi
if ! grep -rn "options:[[:space:]]*\.listenOnly" "$SRC" >/dev/null 2>&1; then
  flag "no .listenOnly tap found (the passive tap must exist and be listen-only)"
fi

# 2. No window may take keyboard focus (canBecomeKey must be false everywhere).
if grep -rn "canBecomeKey:[[:space:]]*Bool[[:space:]]*{[[:space:]]*true" "$SRC" >/dev/null 2>&1; then
  flag "a window returns canBecomeKey = true (would steal the user's typing)"
fi

# 3. The interactive panel must never grab key focus.
PANEL="$SRC/PointerApp/PinnedGlassPanelController.swift"
if [[ -f "$PANEL" ]] && grep -nE "makeKeyAndOrderFront|makeFirstResponder" "$PANEL" >/dev/null 2>&1; then
  flag "PinnedGlassPanelController grabs key focus (makeKey*/makeFirstResponder)"
fi

# 4. No synthetic input injection.
if grep -rnE "CGEventPost|CGEvent\(keyboardEventSource|kCGEventKeyDown" "$SRC" >/dev/null 2>&1; then
  flag "synthetic input posting (halo observes and acts via AX only, never injects keys)"
fi

if [[ $fail -ne 0 ]]; then
  echo "\ncheck-input-safety FAILED — halo could take custody of user input."
  exit 1
fi
echo "check-input-safety OK — listen-only tap, no key-window, no synthetic input."
