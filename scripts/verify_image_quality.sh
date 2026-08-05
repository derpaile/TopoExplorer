#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

"$PROJECT_DIR/.venv/bin/python" preprocess/verify_tiles.py "${1:-MapData/Germany}"
"$PROJECT_DIR/scripts/verify_runtime.sh" "${1:-MapData/Germany}" "${2:-References/Generated}"
