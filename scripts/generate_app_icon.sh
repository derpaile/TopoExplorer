#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
ASSET_DIR="$PROJECT_DIR/app/Assets.xcassets/AppIcon.appiconset"
BUILD_DIR="$PROJECT_DIR/.build/icon"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"

mkdir -p "$ASSET_DIR" "$BUILD_DIR" "$PROJECT_DIR/.build/module-cache"

CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache" \
SWIFT_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache" \
swiftc \
  -sdk "$SDK_PATH" \
  -target "$ARCHITECTURE-apple-macosx14.4" \
  "$PROJECT_DIR/packaging/generate_app_icon.swift" \
  -o "$BUILD_DIR/generate_app_icon"

"$BUILD_DIR/generate_app_icon" "$ASSET_DIR" "$PROJECT_DIR/app/AppIcon.icns"
echo "$PROJECT_DIR/app/AppIcon.icns"
