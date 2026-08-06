#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ ! -x .venv/bin/python ]]; then
  echo "Python-Umgebung fehlt. Siehe README.md."
  exit 1
fi

exec .venv/bin/python preprocess/fuse_landcover.py "$@"
