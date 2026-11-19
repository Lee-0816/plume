#!/bin/bash
# Build Plume.app into ./build
#   scripts/build.sh            release build for this Mac's architecture
#   scripts/build.sh --universal  arm64 + x86_64
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Plume.app"

ARCH_FLAGS=()
if [ "${1:-}" = "--universal" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling Swift sources"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN_DIR/Plume" "$APP/Contents/MacOS/Plume"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Welcome.md" "$APP/Contents/Resources/Welcome.md"
printf 'APPL????' > "$APP/Contents/PkgInfo"

"$ROOT/scripts/assemble-editor.sh" "$APP/Contents/Resources/editor"

echo "▸ Rendering icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signing (ad hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo "✓ Built $APP"
