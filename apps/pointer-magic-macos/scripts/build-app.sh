#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
CONFIGURATION=${CONFIGURATION:-release}
APP_ROOT="$ROOT/.build/app"
APP="$APP_ROOT/Pointer Magic.app"
CONTENTS="$APP/Contents"
IDENTITY=${POINTER_MAGIC_CODESIGN_IDENTITY:--}
ENTITLEMENTS="$ROOT/Resources/PointerMagic.entitlements"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product PointerMagic
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)

rm -rf "$APP"
install -d "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BIN_DIR/PointerMagic" "$CONTENTS/MacOS/PointerMagic"
install -m 644 "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
install -m 644 "$ROOT/Resources/MenuBarIcon.png" "$CONTENTS/Resources/MenuBarIcon.png"
install -m 644 "$ROOT/Resources/MenuBarIcon@2x.png" "$CONTENTS/Resources/MenuBarIcon@2x.png"

plutil -lint "$ENTITLEMENTS" >/dev/null

codesign \
    --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp=none \
    --sign "$IDENTITY" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "$APP"

if [[ ${1:-} == "--open" ]]; then
    open "$APP"
fi
