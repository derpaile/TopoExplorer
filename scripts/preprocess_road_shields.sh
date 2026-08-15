#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

exec .venv/bin/python preprocess/road_shields.py "$@"
