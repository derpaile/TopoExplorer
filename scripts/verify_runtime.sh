#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURE="$(uname -m)"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
VERIFIER="$PROJECT_DIR/.build/TopoRuntimeVerifier"

mkdir -p "$MODULE_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
swiftc \
  -sdk "$SDK_PATH" \
  -target "${ARCHITECTURE}-apple-macosx14.4" \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Metal \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -lz \
  "$PROJECT_DIR/Sources/TopoExplorer/TileCache.swift" \
  "$PROJECT_DIR/Sources/TopoExplorer/MetalShader.swift" \
  "$PROJECT_DIR/Sources/TopoExplorer/StyleSettings.swift" \
  "$PROJECT_DIR/Sources/TopoExplorer/MapManifest.swift" \
  "$PROJECT_DIR/Sources/TopoExplorer/MapReference.swift" \
  "$PROJECT_DIR/Tools/RuntimeVerifier.swift" \
  -o "$VERIFIER"

if [[ "${TOPO_VERIFY_BUILD_ONLY:-0}" == "1" ]]; then
  exit 0
fi

cd "$PROJECT_DIR"
exec "$VERIFIER" "${@:-MapData/Germany}"
