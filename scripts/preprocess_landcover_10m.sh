#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ ! -x .venv/bin/python ]]; then
  echo "Python-Umgebung fehlt: .venv/bin/python" >&2
  exit 1
fi

exec .venv/bin/python preprocess/rich_landcover_10m.py "$@"
