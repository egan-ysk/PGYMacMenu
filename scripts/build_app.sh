#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/PGYMacMenu.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/PGYMacMenu"
ARM_EXECUTABLE="$BUILD_DIR/PGYMacMenu-arm64"
X86_EXECUTABLE="$BUILD_DIR/PGYMacMenu-x86_64"

mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

plutil -lint "$ROOT_DIR/Resources/Info.plist" >/dev/null

compile_arch() {
  local target="$1"
  local output="$2"
  swiftc \
    -swift-version 5 \
    -target "$target-apple-macosx15.0" \
    -Osize \
    -framework AppKit \
    -framework CoreImage \
    -framework Foundation \
    -framework Security \
    -framework UniformTypeIdentifiers \
    "$ROOT_DIR"/Sources/PGYMacMenu/*.swift \
    -o "$output"
}

compile_arch arm64 "$ARM_EXECUTABLE"
compile_arch x86_64 "$X86_EXECUTABLE"
lipo -create "$ARM_EXECUTABLE" "$X86_EXECUTABLE" -output "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
