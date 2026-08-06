#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

SOURCE="MapData/Germany-10m"
TARGET="MapData/Germany"

if [[ ! -f "$SOURCE/manifest.json" || -f "$SOURCE/.incomplete" ]]; then
  echo "Die neue 10-m-Karte ist nicht vollständig." >&2
  exit 1
fi

if [[ -d "$TARGET" ]]; then
  BACKUP="MapData/Germany-50m-backup-$(date +%Y%m%d-%H%M%S)"
  mv "$TARGET" "$BACKUP"
  echo "Bisherige Karte gesichert: $BACKUP"
fi
mv "$SOURCE" "$TARGET"
echo "10-m-Karte aktiviert: $TARGET"
