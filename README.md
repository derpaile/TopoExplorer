# TopoExplorer

Native macOS-Karte für die vorhandenen Deutschlanddaten. Die App lädt nur sichtbare Kacheln, berechnet das Relief in Metal und lässt alle elf Farben live verändern.

## Projektstruktur

- `Sources/TopoExplorer/`: native SwiftUI-/Metal-App
- `preprocess/`: fensterweise Kachelerzeugung
- `Data/Raw/`: lokale Quelldaten, nach Datentyp geordnet und nicht in Git
- `MapData/Germany/`: erzeugte Deutschland-Kacheln, nicht in Git
- `References/`: kleine, reproduzierbare Bildreferenzen für fünf Landschaftstypen
- `scripts/`: Build, Aufbereitung und Laufzeitprüfung

## In zwei Befehlen vorbereiten und bauen

```sh
./scripts/prepare_all.sh
./scripts/build_app.sh
```

Der erste Befehl richtet die lokale Python-Umgebung ein und erzeugt Raster-,
Gesamtlandbedeckungs-, Vektor- und Ortskacheln. Abgebrochene Läufe werden fortgesetzt.
Die feinste Rasterauflösung beträgt 50 Meter.

Erwartete Quelldateien:

```text
Data/Raw/LandCover/Land_Cover_DE_2015.tif
Data/Raw/LandCover/classification_map_germany_2020_v02.tif
Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff
Data/Raw/OSM/germany-latest.osm.pbf
Data/Raw/BKG/gn250/GN250.csv
```

Die amtlichen Deutschland-Geonamen GN250 werden bei `prepare_all.sh` automatisch
geladen. Sie ergänzen die OSM-Orte um Berge, Landschaften, Gewässer, Naturgebiete,
Inseln und Höhlen.

## App bauen und starten

```sh
open .build/app/TopoExplorer.app
```

Die App findet `MapData/Germany` automatisch. Alternativ kann der Datenordner über „Kartendaten wählen“ geöffnet werden.

Mit einer vollständigen Xcode-Installation kann das Projekt alternativ über `Package.swift` geöffnet werden. Das direkte Build-Skript genügt auch mit den Apple Command Line Tools.

## Bedienung

- Ziehen: Karte verschieben
- Mausrad oder Trackpad-Zoom: zoomen
- Doppelklick: hineinzoomen
- `0`: ganz Deutschland einpassen
- `+` / `-`: zoomen
- Farbflächen rechts: Farben sofort ändern
- Reliefregler: Stärke, Überhöhung und Kontrast ändern
- Referenzansichten: Harz, Alpen, Küste, Ruhrgebiet und Flachland direkt anspringen
- Ebenen: Straßen, Bahn, Flüsse, Grenzen, Orte und Natur-/Geländenamen einzeln schalten
- Suche: Ortsname oder EPSG:3035-Koordinaten eingeben
- Mauszeiger: Koordinaten, Höhe und Landklasse ablesen
- Gesamtkarte: komplementäre Details aus den Klassifikationen 2015 und 2020
- Export: echter Metal-Neuaufbau bis 4× mit feineren Kacheln, Maßstab und Stil-Datei

Stile und Lesezeichen werden dauerhaft lokal gespeichert. Eigene Kartenstile
lassen sich als `.topostyle` austauschen.

## Bildqualität prüfen

```sh
./scripts/verify_image_quality.sh
```

Die Prüfung validiert alle Kacheldaten, vergleicht jeden überlappenden Relief-Kachelrand bytegenau und rendert die fünf Referenzansichten erneut.
