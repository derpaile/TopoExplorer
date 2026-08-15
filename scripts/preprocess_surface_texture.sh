#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ ! -x .venv/bin/python ]]; then
  echo "Python-Umgebung fehlt. Zuerst ./scripts/prepare_all.sh ausführen."
  exit 1
fi

exec .venv/bin/python preprocess/surface_texture.py "$@"
