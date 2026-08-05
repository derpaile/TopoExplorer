# Lokale Kartendaten

`Raw/` enthält große lokale Quelldaten und wird nicht in Git aufgenommen:

- `LandCover/`: Landbedeckung 2015 und 2020
- `Elevation/`: verwendetes GMTED-Höhenmodell und Metadaten
- `OSM/`: Deutschland-PBF sowie Orts- und Bahncache
- `Boundaries/`: präzise Ländergrenzen in EPSG:3035

`../MapData/Germany/` enthält die daraus erzeugte Kachelpyramide und wird ebenfalls nicht eingecheckt. Beide Verzeichnisse lassen sich lokal sichern oder neu erzeugen.
