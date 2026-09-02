#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

./scripts/check_source_data.sh

echo "1/9 Basiskarte"
TOPO_DEFER_FULL_VERIFY=1 ./scripts/prepare_all.sh "$@"

echo "2/9 Bevölkerung"
./scripts/fetch_zensus_population.sh
./scripts/preprocess_population.sh

echo "3/9 Oberflächensubstrat"
./scripts/fetch_bgr_substrate.sh

echo "4/9 Oberflächennahe Geologie"
./scripts/fetch_bgr_geology.sh

echo "5/9 Rohstoffvorkommen und Erze"
./scripts/fetch_bgr_resources.sh

echo "6/9 Geomorphographische Einheiten"
./scripts/fetch_bgr_geomorphography.sh

echo "7/9 Grundwasserflurabstand"
./scripts/fetch_bgr_groundwater.sh

echo "8/9 Sentinel-2-Oberflächentextur 2025-Q2"
./scripts/preprocess_surface_texture.sh \
  --germany \
  --quarter 2025-Q2 \
  --band-profile rgb

echo "9/9 Vollständige Prüfung und Referenzbilder"
./scripts/verify_image_quality.sh

echo "Vollständiger Screenshot-Stand: MapData/Germany und References/Generated"
