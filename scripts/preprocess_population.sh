#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="${1:-$PROJECT_DIR/Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif}"
MAP_DATA="${2:-$PROJECT_DIR/MapData/Germany}"

if [[ ! -x "$PROJECT_DIR/.venv/bin/python" ]]; then
  echo "Python-Umgebung fehlt. Zuerst ./scripts/prepare_all.sh ausführen." >&2
  exit 1
fi

"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/preprocess/population_tiles.py" \
  --source "$SOURCE" \
  --map-data "$MAP_DATA"
