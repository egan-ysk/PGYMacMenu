#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/PGYMacMenu.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/PGYMacMenu"
ARM_EXECUTABLE="$BUILD_DIR/PGYMacMenu-arm64"
X86_EXECUTABLE="$BUILD_DIR/PGYMacMenu-x86_64"
ICON_SOURCE="$ROOT_DIR/Resources/AppIconSource.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_FILE="$BUILD_DIR/AppIcon.icns"

mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

plutil -lint "$ROOT_DIR/Resources/Info.plist" >/dev/null

generate_app_icon() {
  if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing app icon source: $ICON_SOURCE" >&2
    exit 1
  fi

  local width height
  width="$(sips -g pixelWidth "$ICON_SOURCE" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$ICON_SOURCE" | awk '/pixelHeight/ { print $2 }')"
  if [[ "$width" != "1024" || "$height" != "1024" ]]; then
    echo "App icon source must be 1024x1024 pixels (found ${width}x${height})" >&2
    exit 1
  fi

  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  local filename size
  while read -r filename size; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$filename" >/dev/null
  done <<'EOF'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
EOF

  iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"
}

compile_arch() {
  local target="$1"
  local output="$2"
  swiftc \
    -swift-version 5 \
    -target "$target-apple-macosx15.0" \
    -Osize \
    -framework AppKit \
    -framework CoreImage \
    -framework CryptoKit \
    -framework Foundation \
    -framework Security \
    -framework UniformTypeIdentifiers \
    "$ROOT_DIR"/Sources/PGYMacMenu/*.swift \
    -o "$output"
}

generate_app_icon
compile_arch arm64 "$ARM_EXECUTABLE"
compile_arch x86_64 "$X86_EXECUTABLE"
lipo -create "$ARM_EXECUTABLE" "$X86_EXECUTABLE" -output "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
