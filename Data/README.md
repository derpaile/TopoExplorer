# Lokale Kartendaten

`Raw/` enthält große lokale Quelldaten und wird nicht in Git aufgenommen:

- `LandCover/`: Landbedeckung 2015 und 2020
- `Elevation/`: verwendetes GMTED-Höhenmodell und Metadaten
- `OSM/`: Deutschland-PBF sowie Orts- und Bahncache
- `Boundaries/`: präzise Ländergrenzen in EPSG:3035

`../MapData/Germany/` enthält die daraus erzeugte Kachelpyramide und wird ebenfalls nicht eingecheckt. Beide Verzeichnisse lassen sich lokal sichern oder neu erzeugen.

## Vektoren und Orte

Straßen, Bahnlinien, Fließgewässer, Verwaltungsgrenzen und Orte werden einmalig
in dieselbe Kachelstruktur wie die Rasterkarte geschrieben:

```sh
./scripts/preprocess_vectors.sh
```

Ein abgebrochener Lauf setzt vorhandene Arbeitsstufen fort. `--force` baut alle
Vektordaten neu, `--dry-run` prüft Eingaben und Rasteraufteilung. Standardmäßig
werden diese lokalen Quellen verwendet:

- `OSM/germany-latest.osm.pbf`: Straßen, Gewässer und Verwaltungsgrenzen
- `OSM/railways.geojson`: Bahncache
- `OSM/places.geojson`: Ortsname, Ortsart und Bevölkerung

Die Ausgabe liegt in `../MapData/Germany/Vectors/`. Format und Swift-taugliches
Binärlayout sind in `preprocess/VECTOR_FORMAT.md` beschrieben. Der zentrale,
komprimierte `places-index.json.z` dient der Ortssuche.

Alle erzeugten Kacheln und Records lassen sich anschließend dekodieren und
gegen das Manifest prüfen:

```sh
./scripts/verify_vectors.sh
```
