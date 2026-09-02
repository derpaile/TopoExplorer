<p align="center">
  <img src="app/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="112" alt="TopoExplorer App-Icon">
</p>

<h1 align="center">TopoExplorer</h1>

<p align="center">
  <strong>Deutschland als interaktive 10-m-Landoberflächenkarte – nativ, lokal und mit Metal gerendert.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white" alt="Swift 5.10">
  <img src="https://img.shields.io/badge/Rendering-Metal-6E5CFF" alt="Metal Rendering">
  <img src="https://img.shields.io/badge/Datenverarbeitung-lokal-2E8B57" alt="Lokale Datenverarbeitung">
</p>

![TopoExplorer zeigt Landbedeckung, Oberflächentextur und Relief im Raum Hannover](References/Generated/hannover-fachkarte-surface-relief.png)

<p align="center"><sub>Hannover: Landbedeckung, Sentinel-2-Feinstruktur und Relief in einer gemeinsamen Darstellung.</sub></p>

TopoExplorer verbindet hochauflösende Landbedeckung mit Gelände, Infrastruktur,
Bevölkerung und geowissenschaftlichen Fachkarten. Sichtbare Kacheln werden
bedarfsgerecht geladen und direkt auf der GPU aufgebaut. Die Quelldaten und
Analysen bleiben auf dem eigenen Mac.

## Auf einen Blick

| | |
|---|---|
| **10-m-Landoberfläche** | 40 durchsuchbare und frei färbbare Klassen für ganz Deutschland |
| **Metal-Relief** | Live steuerbare Stärke, Überhöhung und Kontrast ohne vorgerenderte Schummerung |
| **Fachkarten** | Substrat, Geologie, Rohstoffe, Reliefform und Grundwasser als eigenständige Kartenfamilie |
| **Lokale Analyse** | Flächen, Profile, Bevölkerung, Dichte, Höhenraum und Landschaftsmosaik auswerten |
| **Offenes Feldbuch** | Fundstellen vergleichen, kommentieren und verlustfrei als GeoJSON austauschen |
| **Kartografischer Export** | Karte bis 4× neu rendern, inklusive feinerer Kacheln, Maßstab und Stil-Datei |

## Kartenansichten

<table>
  <tr>
    <td width="50%">
      <img src="References/Generated/harz.png" alt="TopoExplorer-Kartenansicht des Harzes"><br>
      <sub><b>Harz</b> · Waldarten, Landnutzung und ausgeprägtes Relief</sub>
    </td>
    <td width="50%">
      <img src="References/Generated/alpen.png" alt="TopoExplorer-Kartenansicht der Alpen"><br>
      <sub><b>Alpen</b> · Höhenstufen, Täler, Seen und Siedlungsachsen</sub>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="References/Generated/ruhrgebiet.png" alt="TopoExplorer-Kartenansicht des Ruhrgebiets"><br>
      <sub><b>Ruhrgebiet</b> · Verdichtungsraum und grüne Freiraumstruktur</sub>
    </td>
    <td width="50%">
      <img src="References/Generated/kueste.png" alt="TopoExplorer-Kartenansicht der deutschen Küste"><br>
      <sub><b>Küste</b> · Marsch, Ackerflächen, Gewässer und Inseln</sub>
    </td>
  </tr>
</table>

## Schnellstart

> **Wichtig:** Das Repository enthält den Quellcode, aber keine fertige
> Deutschlandkarte. Der vollständige Datenaufbau erzeugt lokal etwa **9–10 GB**
> Kartendaten und benötigt zusätzlich das aktuelle Deutschland-PBF von
> OpenStreetMap. Für einen problemlosen Lauf sind mindestens **20 GB freier
> Speicher** sinnvoll.

Vorausgesetzt werden macOS 14 oder neuer, die Apple Command Line Tools,
Python 3 und eine Internetverbindung. `osmium-tool` wird benötigt; bei
vorhandenem Homebrew installiert das Vorbereitungsskript es automatisch.

### 1. Drei Pflichtquellen ablegen

| Datengrundlage | Wofür? | Erwarteter Pfad | Beschaffung |
|---|---|---|---|
| **DLR Land Cover DE 2015** | Deutschlandgrenze und Wald-Offenflächen | `Data/Raw/LandCover/Land_Cover_DE_2015.tif` | [DLR-Download, ZIP 244 MiB](https://download.geoservice.dlr.de/LCC_DE/files/Land_Cover_DE_2015_v1.zip) entpacken |
| **GMTED2010 Mean, 7,5″** | Relief und Höhenabfragen | `Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff` | [USGS GMTED2010](https://www.usgs.gov/centers/eros/science/usgs-eros-archive-digital-elevation-global-multi-resolution-terrain-elevation), als GeoTIFF für Deutschland |
| **OpenStreetMap Deutschland** | Straßen, Bahn, Gewässer, Grenzen, Orte und Energie | `Data/Raw/OSM/germany-latest.osm.pbf` | [Geofabrik-PBF, derzeit etwa 4,5 GB](https://download.geofabrik.de/europe/germany-latest.osm.pbf) |

Ordner anlegen und die beiden direkt verfügbaren Dateien laden:

```sh
mkdir -p Data/Raw/LandCover Data/Raw/Elevation Data/Raw/OSM

curl -fL --continue-at - \
  -o Data/Raw/LandCover/Land_Cover_DE_2015_v1.zip \
  https://download.geoservice.dlr.de/LCC_DE/files/Land_Cover_DE_2015_v1.zip
unzip -o -j Data/Raw/LandCover/Land_Cover_DE_2015_v1.zip \
  -d Data/Raw/LandCover

curl -fL --continue-at - \
  -o Data/Raw/OSM/germany-latest.osm.pbf \
  https://download.geofabrik.de/europe/germany-latest.osm.pbf
```

Beim USGS-Export **Mean**, **7,5 arc-seconds**, **GeoTIFF** und einen
Deutschlandausschnitt wählen. Die Datei anschließend exakt
`gmted2010_mean_7p5arcsec.tiff` nennen. Andere DEMs funktionieren ebenfalls,
sofern Rasterio sie lesen kann; sie werden automatisch nach EPSG:3035
reprojiziert. Details und Datenanforderungen stehen unter
[Datengrundlagen einrichten](docs/Datenquellen.md).

### 2. Copernicus-Zugang für den Screenshot-Inhalt einrichten

Die gezeigte Feinstruktur stammt aus dem Sentinel-2-Quartalsmosaik 2025-Q2.
Für denselben Kartenstand wird einmalig ein OAuth-Client im
[Copernicus Data Space](https://dataspace.copernicus.eu/) benötigt. Client-ID
und Secret werden im macOS-Schlüsselbund gespeichert, nicht im Repository:

```sh
./scripts/configure_cdse_credentials.sh
```

Der deutschlandweite RGB-Detailabruf benötigt ungefähr 26.700–28.000 Sentinel
Hub Processing Units. Er passt damit knapp in ein 30.000-PU-Kontingent.

### 3. Eingaben prüfen

```sh
./scripts/check_source_data.sh
```

Der Check prüft die drei lokalen Pflichtquellen und den CDSE-Zugang. Zensus,
BGR-Daten, GN250, WorldCover, EUCROPMAP und ForestPaths werden im Vollaufbau
automatisch beschafft.

### 4. Vollständigen Screenshot-Stand erzeugen

```sh
./scripts/prepare_complete.sh
./scripts/build_app.sh
```

Danach liegt die startbereite Anwendung hier:

```sh
open .build/app/TopoExplorer.app
```

`prepare_complete.sh` erzeugt genau die Datenausstattung, aus der die Bilder in
dieser README gerendert werden:

- 40 Landbedeckungsklassen aus WorldCover, EUCROPMAP, ForestPaths und DLR,
- GMTED-Relief sowie OSM-/GN250-Orientierungsebenen,
- Zensus-2022-Bevölkerung im 100-m-Gitter,
- BGR-Substrat, Geologie, Rohstoffe, Geomorphographie und Grundwasser,
- deutschlandweite Sentinel-2-Oberflächentextur aus 2025-Q2,
- neu gerenderte Dateien unter `References/Generated`.

Downloads und Verarbeitung sind fortsetzbar. Nach einem Abbruch denselben
Befehl erneut starten. Erst die abschließende Prüfung rendert die Screenshot-
Galerie neu und bestätigt, dass alle dargestellten Inhalte vorhanden sind.

### Nur die reduzierte Basiskarte

```sh
./scripts/prepare_all.sh
```

Dieser kürzere Lauf ist für Entwicklung ohne Zensus, BGR-Fachkarten und
Sentinel-Textur gedacht. Er reproduziert die vollständigen README-Screenshots
ausdrücklich **nicht**. Der App-Code lässt sich unabhängig davon über
`Package.swift` in Xcode öffnen.

## Was sich erkunden lässt

- **Landoberfläche:** Klassen suchen, einzeln oder gruppenweise umfärben,
  ausgrauen und als Naturatlas, Kulturarten-, Waldarten- oder Kontrastthema lesen.
- **Orientierung:** Straßen, Bahn, Flüsse, Grenzen, Orte, Landschaften und
  Energieinfrastruktur passend zur Zoomstufe einblenden.
- **Fundstellen:** Höhe, Hangneigung, Exposition, Landklasse, Quellenmaßstab und
  Umgebung direkt am Mauszeiger oder an gespeicherten Punkten untersuchen.
- **Analysen:** Rechtecke für Flächen- und Bevölkerungswerte sowie Linien für
  Höhenprofile und Landklassenabschnitte zeichnen.
- **Fachkarten:** Geologie, Substrat, Rohstoffe, Reliefform und Grundwasser
  exklusiv als Overlay oder Basiskarte verwenden.
- **Oberflächentextur:** neutrale Sentinel-2-Feinstruktur klassen- und
  zoomabhängig mit Landbedeckung, Relief und Fachkarten kombinieren.

## Bedienung in 30 Sekunden

| Aktion | Steuerung |
|---|---|
| Karte verschieben | Ziehen |
| Zoomen | Mausrad, Trackpad, Doppelklick oder `+` / `-` |
| Deutschland einpassen | `0` |
| Stöberpalette öffnen | `⌘K` |
| Datenatlas, Sammlung und Analysen | adaptive Kartenleiste |
| Stil austauschen | `.topostyle` importieren oder exportieren |

Eine vollständige Einführung steht in der
[Bedienungsanleitung](docs/Bedienungsanleitung.md).

## Projektstruktur

```text
Sources/TopoExplorer/   SwiftUI-, AppKit- und Metal-Anwendung
preprocess/             reproduzierbare Datenaufbereitung
scripts/                Build, Vorbereitung und Qualitätsprüfung
References/Generated/   Referenzrenderings für Landschaftstypen
Data/Raw/               lokale Quelldaten, nicht in Git
MapData/Germany/        erzeugte Kartenpyramide, nicht in Git
```

## Dokumentation

- [Bedienungsanleitung](docs/Bedienungsanleitung.md)
- [Datenquellen und Lizenzen](docs/Datenquellen.md)
- [Geowissenschaftliche Fachkarten](docs/Geowissenschaften.md)
- [Sentinel-Oberflächentextur](docs/Oberflaechentextur.md)
- [Datenordner und Sicherheitszugriff](docs/Datenordner-Lesezeichen.md)

## Qualität prüfen

```sh
./scripts/verify_image_quality.sh
```

Die Prüfung validiert Kacheldaten, vergleicht überlappende Relief-Kachelränder
bytegenau und rendert die Referenzlandschaften erneut.
