#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -r preprocess/requirements.txt

if ! command -v osmium >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install osmium-tool
  else
    echo "Für Vektorkacheln wird osmium-tool benötigt." >&2
    exit 1
  fi
fi

./scripts/preprocess_landcover_10m.sh "$@"
./scripts/preprocess_vectors.sh \
  --manifest MapData/Germany-10m/manifest.json \
  --output MapData/Germany-10m/Vectors
./scripts/activate_landcover_10m.sh

POPULATION_SOURCE="Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif"
if [[ "${TOPO_DEFER_FULL_VERIFY:-0}" == "1" ]]; then
  echo "Bevölkerung folgt in Stufe 2 des Vollaufbaus."
elif [[ -f "$POPULATION_SOURCE" ]]; then
  ./scripts/preprocess_population.sh "$POPULATION_SOURCE"
else
  echo "Reduzierter Lauf: Bevölkerungsanalysen werden übersprungen."
  echo "Für den vollständigen Stand ./scripts/prepare_complete.sh verwenden."
fi

./scripts/verify_vectors.sh
if [[ "${TOPO_DEFER_FULL_VERIFY:-0}" == "1" ]]; then
  .venv/bin/python preprocess/verify_tiles.py MapData/Germany
elif [[ -f "$POPULATION_SOURCE" ]]; then
  ./scripts/verify_image_quality.sh
else
  .venv/bin/python preprocess/verify_tiles.py MapData/Germany
fi

echo "Kartendaten vollständig: MapData/Germany"
