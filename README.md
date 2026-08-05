# TopoExplorer

Native macOS-Karte für die vorhandenen Deutschlanddaten. Die App lädt nur sichtbare Kacheln, berechnet das Relief in Metal und lässt alle acht Farben live verändern.

## Projektstruktur

- `Sources/TopoExplorer/`: native SwiftUI-/Metal-App
- `preprocess/`: fensterweise Kachelerzeugung
- `Data/Raw/`: lokale Quelldaten, nach Datentyp geordnet und nicht in Git
- `MapData/Germany/`: erzeugte Deutschland-Kacheln, nicht in Git
- `References/`: kleine, reproduzierbare Bildreferenzen für fünf Landschaftstypen
- `scripts/`: Build, Aufbereitung und Laufzeitprüfung

## Kartendaten einmalig erzeugen

```sh
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r preprocess/requirements.txt
./scripts/preprocess_germany.sh
```

Die voreingestellte feinste Auflösung beträgt 50 m und entspricht dem letzten Python-Renderer. Ein abgebrochener Lauf kann mit demselben Befehl fortgesetzt werden.

Erwartete Quelldateien:

```text
Data/Raw/LandCover/Land_Cover_DE_2015.tif
Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff
```

## App bauen und starten

```sh
./scripts/build_app.sh
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

Die gewählten Farben und Reliefwerte werden dauerhaft lokal gespeichert.

## Bildqualität prüfen

```sh
./scripts/verify_image_quality.sh
```

Die Prüfung validiert alle Kacheldaten, vergleicht jeden überlappenden Relief-Kachelrand bytegenau und rendert die fünf Referenzansichten erneut.
