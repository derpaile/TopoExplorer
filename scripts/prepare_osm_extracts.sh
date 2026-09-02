#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

PBF="${1:-Data/Raw/OSM/germany-latest.osm.pbf}"
RAILWAYS="${2:-Data/Raw/OSM/railways.geojson}"
PLACES="${3:-Data/Raw/OSM/places.geojson}"

if [[ ! -f "$PBF" ]]; then
  echo "OSM-Quelldatei fehlt: $PBF" >&2
  exit 1
fi
if ! command -v osmium >/dev/null 2>&1; then
  echo "osmium-tool fehlt. Installation: brew install osmium-tool" >&2
  exit 1
fi

mkdir -p "${RAILWAYS:h}" "${PLACES:h}"
if [[ -f "$RAILWAYS" && -f "$PLACES" ]]; then
  echo "OSM-Ableitungen vorhanden: $RAILWAYS und $PLACES"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/topo-osm-extracts.XXXXXX")"
cleanup() {
  rm -rf -- "$WORK"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$RAILWAYS" ]]; then
  echo "Erzeuge Bahnlinien aus $PBF …"
  osmium tags-filter -t "$PBF" \
    'w/railway=rail,narrow_gauge,light_rail,subway,tram,funicular,monorail,construction' \
    -o "$WORK/railways.osm.pbf"
  osmium export "$WORK/railways.osm.pbf" -f geojson -o "$WORK/railways.geojson"
  mv "$WORK/railways.geojson" "$RAILWAYS"
fi

if [[ ! -f "$PLACES" ]]; then
  echo "Erzeuge Ortsnamen aus $PBF …"
  osmium tags-filter -t "$PBF" \
    'n/place=city,town,village,suburb,quarter,borough,hamlet,isolated_dwelling,locality' \
    -o "$WORK/places.osm.pbf"
  osmium export "$WORK/places.osm.pbf" -f geojson -o "$WORK/places.geojson"
  mv "$WORK/places.geojson" "$PLACES"
fi

echo "OSM-Ableitungen vollständig: $RAILWAYS und $PLACES"
