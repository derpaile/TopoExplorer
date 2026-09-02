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
| **Fachkarten** | Substrat, Geologie, Reliefform und Grundwasser als eigenständige Kartenfamilie |
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

Vorausgesetzt werden macOS 14 oder neuer, die Apple Command Line Tools und
Python 3. Die großen Roh- und Kartendaten gehören bewusst nicht zum Repository.

```sh
./scripts/prepare_all.sh
./scripts/build_app.sh
```

Danach liegt die startbereite Anwendung hier:

```sh
open .build/app/TopoExplorer.app
```

`prepare_all.sh` richtet die lokale Python-Umgebung ein, installiert bei
vorhandenem Homebrew das benötigte `osmium-tool` und erzeugt fortsetzbar die
Landbedeckungs-, Vektor-, Orts- und Bevölkerungskacheln. Alternativ lässt sich
das Projekt über `Package.swift` in Xcode öffnen.

### Benötigte Quelldateien

```text
Data/Raw/LandCover/Land_Cover_DE_2015.tif
Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff
Data/Raw/OSM/germany-latest.osm.pbf
Data/Raw/BKG/gn250/GN250.csv
Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif
```

Die amtlichen GN250-Geonamen werden während der Vorbereitung automatisch
geladen. Optionale Behörden-, Landes- und Sentinel-Daten werden getrennt
aufbereitet; vor ihrer Nutzung ist die jeweilige Lizenz zu prüfen.

## Was sich erkunden lässt

- **Landoberfläche:** Klassen suchen, einzeln oder gruppenweise umfärben,
  ausgrauen und als Naturatlas, Kulturarten-, Waldarten- oder Kontrastthema lesen.
- **Orientierung:** Straßen, Bahn, Flüsse, Grenzen, Orte, Landschaften und
  Energieinfrastruktur passend zur Zoomstufe einblenden.
- **Fundstellen:** Höhe, Hangneigung, Exposition, Landklasse, Quellenmaßstab und
  Umgebung direkt am Mauszeiger oder an gespeicherten Punkten untersuchen.
- **Analysen:** Rechtecke für Flächen- und Bevölkerungswerte sowie Linien für
  Höhenprofile und Landklassenabschnitte zeichnen.
- **Fachkarten:** Geologie, Substrat, Reliefform und Grundwasser exklusiv als
  Overlay oder Basiskarte verwenden.
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
