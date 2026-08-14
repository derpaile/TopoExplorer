#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
.venv/bin/python preprocess/bgr_resources_vectors.py "$@"
.venv/bin/python preprocess/geoscience_vectors.py \
  --config Data/Raw/Geoscience/bgr-vectors.json \
  --manifest MapData/Germany/manifest.json \
  --vectors MapData/Germany/Vectors
