#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
raw="Data/Raw/Geoscience/BGR/BUEK250"
mkdir -p "$raw"
if [[ ! -f "$raw/buek250_mgm_utm_v60.zip" ]]; then
  curl -sL --fail -o "$raw/buek250_mgm_utm_v60.zip" \
    'https://download.bgr.de/bgr/boden/BUEK250/gpkg/buek250_mgm_utm_v60.zip'
fi
if [[ ! -f "$raw/buek250_sachdatenbank_v10.zip" ]]; then
  curl -sL --fail -o "$raw/buek250_sachdatenbank_v10.zip" \
    'https://download.bgr.de/bgr/boden/BUEK250-SachDB/SQLite/buek250_sachdatenbank_v10.zip'
fi
if [[ ! -f "$raw/buek250_mgm_utm_v60.gpkg" ]]; then
  unzip -o -j "$raw/buek250_mgm_utm_v60.zip" 'buek250_mgm_utm_v60.gpkg' -d "$raw"
fi
if [[ ! -f "$raw/buek250_sachdatenbank_v10.sqlite" ]]; then
  unzip -o -j "$raw/buek250_sachdatenbank_v10.zip" 'buek250_sachdatenbank_v10.sqlite' -d "$raw"
fi
.venv/bin/python preprocess/bgr_buek250_substrate.py "$@"
