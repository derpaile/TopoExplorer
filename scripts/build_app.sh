#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
TARGET="${ARCHITECTURE}-apple-macosx14.4"
BUILD_DIR="$PROJECT_DIR/.build/app"
APP="$BUILD_DIR/TopoExplorer.app"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreText \
  -framework ImageIO \
  -framework Metal \
  -framework MetalKit \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -lz \
  "$PROJECT_DIR"/Sources/TopoExplorer/*.swift \
  -o "$APP/Contents/MacOS/TopoExplorer"

cp "$PROJECT_DIR/app/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$PROJECT_DIR/app/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
