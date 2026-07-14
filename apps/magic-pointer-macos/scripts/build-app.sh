#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
CONFIGURATION=${CONFIGURATION:-release}
APP_ROOT="$ROOT/.build/app"
APP="$APP_ROOT/Magic Pointer.app"
CONTENTS="$APP/Contents"
IDENTITY=${MAGIC_POINTER_CODESIGN_IDENTITY:--}

cd "$ROOT"
swift build -c "$CONFIGURATION" --product MagicPointer
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)

rm -rf "$APP"
install -d "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BIN_DIR/MagicPointer" "$CONTENTS/MacOS/MagicPointer"
install -m 644 "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

codesign \
    --force \
    --options runtime \
    --timestamp=none \
    --sign "$IDENTITY" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"

if [[ ${1:-} == "--open" ]]; then
    open "$APP"
fi
