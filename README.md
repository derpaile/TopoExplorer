# TopoExplorer

Native macOS-Karte mit 10-m-Landbedeckung für Deutschland. Die App lädt nur
sichtbare Kacheln, berechnet das Relief in Metal und lässt 40 Oberflächenfarben
live verändern.

Optional ergänzt eine eigenständige geowissenschaftliche Produktfamilie
Oberflächensubstrat, oberflächennahe Geologie, geomorphographische
Reliefeinheiten und Grundwasserstufen, ohne die 40 Landbedeckungsklassen zu
verändern.

Für hohe Zoomstufen kann ein neutraler Sentinel-2-Detailkanal reale Feld-,
Wald- und Siedlungsstruktur hinzufügen, ohne Satellitenfarben oder eine zweite
Klassifikation zu übernehmen. Der Hannover-PoC ist in
[`docs/Oberflaechentextur.md`](docs/Oberflaechentextur.md) beschrieben.

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
Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif
```

Die amtlichen Deutschland-Geonamen GN250 werden bei `prepare_all.sh` automatisch
geladen. Sie ergänzen die OSM-Orte um Berge, Landschaften, Gewässer, Naturgebiete,
Inseln und Höhlen.

Die optionalen Behörden- und Landesdaten werden nach lokaler Lizenzprüfung mit
`scripts/preprocess_geoscience.sh` aufbereitet. Konfiguration, COG-Master,
Quellenqualität und TVT2 sind in `docs/Geowissenschaften.md` beschrieben.

Die Sentinel-Oberflächentextur wird für Deutschland fortsetzbar erzeugt. OAuth-
Zugangsdaten liegen dabei im macOS-Schlüsselbund; RGB kann ohne zusätzlichen
Satellitenabruf getrennt auf einem Archivlaufwerk gesichert werden:

```sh
./scripts/configure_cdse_credentials.sh
./scripts/preprocess_surface_texture.sh --germany --band-profile rgb \
  --archive-dir /Volumes/TopoArchiv/Sentinel-2025-Q2 --archive-format uint16
```

Details zu Quoten, Speicherbedarf und Prüfexport: `docs/Oberflaechentextur.md`.

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
- Ebenenstapel: hochauflösende Landoberfläche als feste Basis, genau eine aktive Raster-Fachkarte und kompakte Orientierungsebenen
- Kontext-Schublade: ausgewählte Oberfläche oder Ebene rechts detailliert filtern und gestalten
- Landoberfläche: 40 Klassen durchsuchen, direkt färben, einzeln oder gruppenweise ausgrauen
- Themen: Naturatlas, Kulturarten, Waldarten und Kontrastreich
- Reliefregler: Stärke, Überhöhung und Kontrast ändern
- Oberflächentextur: deutschlandweite, klassen- und zoomabhängige Sentinel-2-Feinstruktur mit Kantenverstärkung und Schnellvergleich bis 60 %; gleichzeitig mit Relief und allen Farb-/Fachkarten
- Referenzansichten: Harz, Alpen, Küste, Ruhrgebiet und Flachland direkt anspringen
- Ebenen: Straßen, Bahn, Flüsse, Grenzen, Orte und Natur-/Geländenamen einzeln schalten
- Energieinfrastruktur: 380-, 220- und 110-kV-Netze sowie Umspannwerke, Transformatoren, Wind-, Solar- und konventionelle Erzeugungsanlagen aus OpenStreetMap
- Beschriftung: Gewässer blau, Naturgebiete grün und Landschaften typografisch vom Ortsnamen getrennt
- Suche: Ortsname oder EPSG:3035-Koordinaten eingeben
- Stöberpalette: mit `⌘K` Landschaftsfunde, freie Datensätze und Werkzeuge
  gemeinsam durchsuchen und direkt öffnen
- Datenatlas: alle verwendeten Quellen nach Kartenfamilie durchsuchen, Lizenz,
  Jahr und Maßstab prüfen und den zugehörigen Karteninhalt direkt anzeigen
- Mauszeiger: Höhe, Hangneigung, Exposition und Landklasse ablesen; ein Klick hält die Fundstelle mit
  EPSG:3035-Koordinate, Fachklasse, Quellenmaßstab und Merkfunktion fest
- Umgebung lesen: um Fundstellen 1-, 3- oder 10-km-Kreise aus Oberflächenanteilen,
  Höhenraum, Relief, Bevölkerung, Dichte, Landschaftsmosaik, nahen Orts-/Naturnamen
  und aktiver Fachkarte lokal auswerten; nummerierte Fundkonstellationen zeigen
  die echte Lage, Namenskarten fliegen den Fund direkt an
- Sammlung: Fundstellen samt Umgebungsmosaik, Radius, Höhenraum, Relief, Bevölkerung, eigenem Namen
  und Notiz bewahren; je zwei Punkte oder Landschaftsbilder direkt vergleichen
- Landschaftsorb: alle Einzelklassen als kompakte Gruppensignatur aus Siedlung,
  Landwirtschaft, Wald und Natur lesen und zwischen Landschaftsbildern vergleichen
- Offenes Feldbuch: Sammlung verlustfrei als GeoJSON mit WGS84-Geometrien,
  EPSG:3035-Originalkoordinaten und Quellen/Lizenzen exportieren oder importieren
- Fachkarten: Substrat, Geologie, Reliefform oder Grundwasser exklusiv als Overlay/Basiskarte, mit eigener Legende, Quelle und Erfassungsmaßstab
- Flächenanalyse: Analyseknopf aktivieren, Rechteck ziehen und Einwohner, Dichte sowie alle vorkommenden Kultur-, Wald- und sonstigen Flächen auswerten
- Landschaftsprofil: Linie von A nach B ziehen und Höhenverlauf, Auf-/Abstieg,
  Landklassenabschnitte und aktive Fachklassen gemeinsam lesen
- Adaptive Kartenleiste und zentrale Tastaturbefehle für Suche, Landschaftsfunde,
  Datenatlas, Sammlung, Analyse, Profil, Export und Seitenleiste
- Gesamtkarte: Kulturarten, Baumgattungen, Naturflächen und Siedlungsdichte
- Export: echter Metal-Neuaufbau bis 4× mit feineren Kacheln, Maßstab und Stil-Datei

Stile und Lesezeichen werden dauerhaft lokal gespeichert. Eigene Kartenstile
lassen sich als `.topostyle` austauschen.

## Bildqualität prüfen

```sh
./scripts/verify_image_quality.sh
```

Die Prüfung validiert alle Kacheldaten, vergleicht jeden überlappenden Relief-Kachelrand bytegenau und rendert die fünf Referenzansichten erneut.
