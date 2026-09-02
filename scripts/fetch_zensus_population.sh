#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

SOURCE_DIR="Data/Raw/Population"
ARCHIVE="$SOURCE_DIR/Zensus2022_Bevoelkerungszahl.zip"
OUTPUT="$SOURCE_DIR/Zensus_Bevoelkerung_100m-Gitter.tif"
URL="https://www.destatis.de/static/DE/zensus/gitterdaten/Zensus2022_Bevoelkerungszahl.zip"

if [[ ! -x .venv/bin/python ]]; then
  echo "Python-Umgebung fehlt. Zuerst ./scripts/prepare_all.sh ausführen." >&2
  exit 1
fi

mkdir -p "$SOURCE_DIR"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Lade Zensus 2022: Bevölkerungszahl im 100-m-Gitter …"
  curl -fL --retry 3 --continue-at - --output "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

if [[ -f "$OUTPUT" && "$OUTPUT" -nt "$ARCHIVE" \
  && "$OUTPUT" -nt preprocess/zensus_population_geotiff.py ]]; then
  echo "Zensus-GeoTIFF vorhanden: $OUTPUT"
  exit 0
fi

.venv/bin/python preprocess/zensus_population_geotiff.py "$ARCHIVE" "$OUTPUT"
