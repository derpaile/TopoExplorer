#!/bin/zsh
set -u

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

missing=0

required() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "OK       $label"
    echo "         $path"
  else
    echo "FEHLT    $label"
    echo "         $path"
    missing=1
  fi
}

optional() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "OK       $label (optional)"
  else
    echo "OPTIONAL $label"
    echo "         $path"
  fi
}

echo "Pflichtquellen für die Basiskarte"
required "Data/Raw/LandCover/Land_Cover_DE_2015.tif" "DLR Land Cover DE 2015"
required "Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff" "GMTED2010 Mean 7,5 Bogensekunden"
required "Data/Raw/OSM/germany-latest.osm.pbf" "OpenStreetMap Deutschland-PBF"

echo
echo "Optionale Analysequelle"
optional "Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif" "Bevölkerung im 100-m-Gitter, EPSG:3035"

echo
echo "Automatisch erzeugt oder geladen"
optional "Data/Raw/OSM/railways.geojson" "Bahnlinien aus dem OSM-PBF"
optional "Data/Raw/OSM/places.geojson" "Orte aus dem OSM-PBF"
optional "Data/Raw/BKG/gn250/GN250.csv" "BKG-Geonamen GN250"
echo "AUTO     ESA WorldCover, EUCROPMAP und ForestPaths"
echo "         werden während ./scripts/prepare_all.sh einzeln geladen"

if (( missing )); then
  echo
  echo "Mindestens eine Pflichtquelle fehlt. Siehe README → Datengrundlagen."
  exit 1
fi

echo
echo "Alle Pflichtquellen sind vorhanden."
