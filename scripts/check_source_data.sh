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

cached() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "OK       $label (bereits vorhanden)"
  else
    echo "AUTO     $label"
    echo "         $path"
  fi
}

echo "Pflichtquellen für die Basiskarte"
required "Data/Raw/LandCover/Land_Cover_DE_2015.tif" "DLR Land Cover DE 2015"
required "Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff" "GMTED2010 Mean 7,5 Bogensekunden"
required "Data/Raw/OSM/germany-latest.osm.pbf" "OpenStreetMap Deutschland-PBF"

echo
echo "Automatisch beschaffte Vollausstattung"
cached "Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif" "Zensus-2022-Bevölkerung im 100-m-Gitter"
echo "AUTO     fünf BGR-Fachkarten einschließlich Rohstoffe"
echo "AUTO     Zensus 2022 wird geladen und als EPSG:3035-GeoTIFF erzeugt"

credentials=0
if [[ -n "${CDSE_CLIENT_ID:-}" && -n "${CDSE_CLIENT_SECRET:-}" ]]; then
  credentials=1
elif [[ -f .env ]] && grep -q '^CDSE_CLIENT_ID=' .env && grep -q '^CDSE_CLIENT_SECRET=' .env; then
  credentials=1
elif security find-generic-password -s de.topoexplorer.cdse -a client-id -w >/dev/null 2>&1 \
  && security find-generic-password -s de.topoexplorer.cdse -a client-secret -w >/dev/null 2>&1; then
  credentials=1
fi
if (( credentials )); then
  echo "OK       Copernicus-Data-Space-Zugang für die Sentinel-2-Textur"
else
  echo "FEHLT    Copernicus-Data-Space-Zugang für die Sentinel-2-Textur"
  echo "         ./scripts/configure_cdse_credentials.sh"
  missing=1
fi

echo
echo "Automatisch aus den Pflichtquellen erzeugt"
cached "Data/Raw/OSM/railways.geojson" "Bahnlinien aus dem OSM-PBF"
cached "Data/Raw/OSM/places.geojson" "Orte aus dem OSM-PBF"
cached "Data/Raw/BKG/gn250/GN250.csv" "BKG-Geonamen GN250"
echo "AUTO     ESA WorldCover, EUCROPMAP und ForestPaths"
echo "         werden während ./scripts/prepare_all.sh einzeln geladen"

if (( missing )); then
  echo
  echo "Der vollständige Screenshot-Aufbau ist noch nicht startbereit."
  echo "Siehe README → Datengrundlagen."
  exit 1
fi

echo
echo "Der vollständige Screenshot-Aufbau ist startbereit."
