#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

.venv/bin/python preprocess/bgr_guek250_tiles.py "$@"
