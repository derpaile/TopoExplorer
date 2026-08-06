# TopoExplorer

Native macOS-Karte mit 10-m-Landbedeckung für Deutschland. Die App lädt nur
sichtbare Kacheln, berechnet das Relief in Metal und lässt 40 Oberflächenfarben
live verändern.

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

Der erste Befehl richtet die lokale Python-Umgebung ein und erzeugt die 10-m-
Landbedeckung sowie Vektor- und Ortskacheln. Abgebrochene Läufe werden
fortgesetzt. WorldCover, EUCROPMAP und ForestPaths werden Datei für Datei
integriert und jeweils sofort gelöscht; das Arbeitslimit beträgt standardmäßig
8 GB. Die bisherige Karte wird bei der Aktivierung nur umbenannt und bleibt als
Sicherung erhalten.

Erwartete Quelldateien:

```text
Data/Raw/LandCover/Land_Cover_DE_2015.tif
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
- Legendenbereiche rechts: alle 40 Farben sofort ändern
- Themen: Naturatlas, Kulturarten, Waldarten und Kontrastreich
- Reliefregler: Stärke, Überhöhung und Kontrast ändern
- Referenzansichten: Harz, Alpen, Küste, Ruhrgebiet und Flachland direkt anspringen
- Ebenen: Straßen, Bahn, Flüsse, Grenzen, Orte und Natur-/Geländenamen einzeln schalten
- Suche: Ortsname oder EPSG:3035-Koordinaten eingeben
- Mauszeiger: Koordinaten, Höhe und Landklasse ablesen
- Gesamtkarte: Kulturarten, Baumgattungen, Naturflächen und Siedlungsdichte
- Export: echter Metal-Neuaufbau bis 4× mit feineren Kacheln, Maßstab und Stil-Datei

Stile und Lesezeichen werden dauerhaft lokal gespeichert. Eigene Kartenstile
lassen sich als `.topostyle` austauschen.

## Bildqualität prüfen

```sh
./scripts/verify_image_quality.sh
```

Die Prüfung validiert alle Kacheldaten, vergleicht jeden überlappenden Relief-Kachelrand bytegenau und rendert die fünf Referenzansichten erneut.
