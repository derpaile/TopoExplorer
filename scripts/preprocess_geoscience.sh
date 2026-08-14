#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

python3 preprocess/geoscience_rasters.py \
  --config "${1:-preprocess/geoscience_config.json}" \
  --manifest "${TOPO_MANIFEST:-MapData/Germany/manifest.json}" \
  "${@:2}"
