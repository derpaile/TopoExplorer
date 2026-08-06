#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

BKG_DIR="Data/Raw/BKG"
ARCHIVE="$BKG_DIR/gn250.utm32s.csv.zip"
CSV="$BKG_DIR/gn250/GN250.csv"
URL="https://daten.gdz.bkg.bund.de/produkte/sonstige/gn250/aktuell/gn250.utm32s.csv.zip"

if [[ -f "$CSV" ]]; then
  echo "Amtliche Geonamen vorhanden: $CSV"
  exit 0
fi

mkdir -p "$BKG_DIR"
echo "Lade amtliche Deutschland-Geonamen GN250 …"
curl -fL --retry 3 --continue-at - --output "$ARCHIVE.part" "$URL"
mv "$ARCHIVE.part" "$ARCHIVE"
unzip -o "$ARCHIVE" \
  'gn250/GN250.csv' \
  'dokumentation/gn250.pdf' \
  'dokumentation/nutzungsbedingungen_gn250.pdf' \
  'dokumentation/datenquellen_gn250.pdf' \
  -d "$BKG_DIR"
echo "Geonamen vollständig: $CSV"
