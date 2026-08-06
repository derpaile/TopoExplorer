#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ ! -x .venv/bin/python ]]; then
  echo "Python-Umgebung fehlt. Einmal ausführen:"
  echo "  uv venv --python 3.12 .venv"
  echo "  uv pip install --python .venv/bin/python -r preprocess/requirements.txt"
  exit 1
fi

if ! command -v osmium >/dev/null 2>&1; then
  echo "osmium-tool fehlt. Einmal ausführen:"
  echo "  brew install osmium-tool"
  exit 1
fi

./scripts/download_supplemental_data.sh
exec .venv/bin/python preprocess/germany_vectors.py "$@"
