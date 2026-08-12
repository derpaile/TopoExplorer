# Lokale Kartendaten

`Raw/` enthält große lokale Quelldaten und wird nicht in Git aufgenommen:

- `LandCover/`: Landbedeckung 2015 für Grenzen und Nadelwald-Offenflächen
- `Elevation/`: verwendetes GMTED-Höhenmodell und Metadaten
- `OSM/`: Deutschland-PBF sowie Orts- und Bahncache
- `BKG/`: amtliche geografische Namen GN250 samt Quelldokumentation
- `Boundaries/`: präzise Ländergrenzen in EPSG:3035
- `Population/`: Zensus-Bevölkerung als 100-m-Gitter für Flächenstatistiken

`../MapData/Germany/` enthält die daraus erzeugte Kachelpyramide und wird ebenfalls nicht eingecheckt. Beide Verzeichnisse lassen sich lokal sichern oder neu erzeugen.

`scripts/preprocess_landcover_10m.sh` erzeugt eine neue Kachelpyramide in
`../MapData/Germany-10m/`. ESA WorldCover 2021, JRC EUCROPMAP 2018 und
ForestPaths 2020 werden nacheinander geladen, direkt in `*.landrich.z`
integriert und wieder entfernt. Dadurch liegen nie mehrere große neue
Datensätze gleichzeitig auf der Platte. Standard: 10 m Landbedeckung, 100 m
Relief-Abtastung und höchstens 8 GB Arbeitsbestand.

Nach erfolgreicher Vektoraufbereitung aktiviert
`scripts/activate_landcover_10m.sh` die neue Karte. Die vorherige
`MapData/Germany` wird ohne Kopie als datierte 50-m-Sicherung umbenannt.

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
- `BKG/gn250/GN250.csv`: Berge, Landschaften, Gewässer, Naturgebiete, Inseln und Höhlen

GN250 wird bei Bedarf automatisch geladen:

```sh
./scripts/download_supplemental_data.sh
```

Die Ausgabe liegt in `../MapData/Germany/Vectors/`. Format und Swift-taugliches
Binärlayout sind in `preprocess/VECTOR_FORMAT.md` beschrieben. Der zentrale,
komprimierte `places-index.json.z` dient der Ortssuche.

Alle erzeugten Kacheln und Records lassen sich anschließend dekodieren und
gegen das Manifest prüfen:

```sh
./scripts/verify_vectors.sh
```

## Bevölkerung und Flächenanalyse

`scripts/preprocess_population.sh` wandelt
`Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif` in kleine, komprimierte
Analysekacheln unter `MapData/Germany/Analysis/` um. Diese Ebene wird nicht
gezeichnet. Die App summiert daraus Einwohner für ein gezogenes Rechteck und
kombiniert sie mit den vorhandenen Kultur-, Wald-, Siedlungs- und Naturklassen.
