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

VECTOR_OUTPUT="MapData/Germany/Vectors"
VECTOR_PBF="Data/Raw/OSM/germany-latest.osm.pbf"
arguments=("$@")
for ((index = 1; index <= ${#arguments}; index++)); do
  case "${arguments[$index]}" in
    --output)
      VECTOR_OUTPUT="${arguments[$((index + 1))]}"
      ;;
    --pbf)
      VECTOR_PBF="${arguments[$((index + 1))]}"
      ;;
  esac
done

.venv/bin/python preprocess/germany_vectors.py "$@"
.venv/bin/python preprocess/road_shields.py \
  --pbf "$VECTOR_PBF" \
  --output "$VECTOR_OUTPUT/road-shields.json.z"
