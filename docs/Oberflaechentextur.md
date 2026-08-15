# Satellitenbasierte Oberflächentextur

TopoExplorer übernimmt aus dem Copernicus Sentinel-2 Level-3 Quarterly Mosaic
ausschließlich lokale Helligkeitsstruktur. Klassen und Farben stammen weiterhin
vollständig aus der Landcover-Karte. Es wird weder ein RGB-Satellitenbild erzeugt
noch gespeichert.

## Zugangsdaten

Im CDSE Sentinel-Hub-Dashboard wird unter „User Settings → OAuth clients“ ein
Client erzeugt. Client-ID und Secret werden nicht in Dateien oder Shell-History
geschrieben, sondern einmal verdeckt im macOS-Schlüsselbund abgelegt:

```sh
./scripts/configure_cdse_credentials.sh
```

Die Pipeline liest beide Werte selbst aus dem Schlüsselbund und erneuert den
kurzlebigen Zugriffstoken während langer Läufe automatisch. Für temporäre
CI-/Serverläufe bleiben `CDSE_CLIENT_ID` und `CDSE_CLIENT_SECRET` möglich. Eine
lokale, durch `.gitignore` ausgeschlossene `.env` mit genau diesen beiden Namen
wird ebenfalls gelesen. Siehe
[offizielle CDSE-Authentifizierung](https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Overview/Authentication.html).

## Hannover-Prüflauf

```sh
./scripts/preprocess_surface_texture.sh --quarter 2025-Q2
```

Der Standardausschnitt umfasst Hannover und Umgebung. Alle benötigten Bänder
werden in einem einzigen Process-API-Aufruf pro Ausschnitt gebündelt und nur im
Arbeitsspeicher verarbeitet. Alternativ können bereits vorhandene Einzelband-Raster benutzt
werden:

```sh
./scripts/preprocess_surface_texture.sh \
  --b02 /pfad/B02.tif --b03 /pfad/B03.tif --b04 /pfad/B04.tif \
  --b08 /pfad/B08.tif --observations /pfad/observations.tif
```

Die Pipeline richtet die Daten am 10-m-Raster des Kartenmanifests in EPSG:3035
aus, bildet eine logarithmische RGB-Helligkeit, ergänzt zurückhaltend NIR,
entfernt großräumige Helligkeit mit einem dreifachen Tiefpass, begrenzt robuste
Ausreißer und kodiert das Ergebnis als UInt8:

- `128`: neutral
- `<128`: lokal dunkler
- `>128`: lokal heller

## Ganz Deutschland und Archiv

Der fortsetzbare Deutschland-Lauf gruppiert vier mal vier TopoExplorer-Kacheln
zu höchstens 2.196 × 2.196 Pixel großen API-Blöcken. Reine Wasser-/No-Data-
Kacheln werden nicht abgerufen. Das Bandprofil `rgb` nutzt B02/B03/B04 sowohl für
den Detailkanal als auch für das optionale Farbsicherungsarchiv; es lädt keine
zusätzlichen, ungenutzten Satellitendaten. Mit dem aktuellen Deutschlandraster
sind rund 1.521 Requests und 26.700–28.000 Processing Units zu erwarten.
Auch die über Deutschland verteilten Normierungsblöcke werden nur einmal geladen,
lokal zwischengespeichert und anschließend direkt als reguläre Ausgabekacheln
verwendet.

```sh
./scripts/preprocess_surface_texture.sh --germany --quarter 2025-Q2 \
  --band-profile rgb \
  --archive-dir /Volumes/TopoArchiv/Sentinel-2025-Q2 \
  --archive-format uint16
```

`uint16` sichert die tatsächlich genutzten RGB-Digitalzahlen verlustfrei.
`jpeg` erzeugt stattdessen ein kleineres Farbsichtarchiv. Unter `Processed/`
enthält dasselbe Archiv die daraus erzeugten neutralen `surface.z`-Varianten
aller Zoomstufen. Bereits abgeschlossene Blöcke stehen in
`SurfaceTexture/germany-build.json`; nach Abbruch oder Quotenreset wird ohne
erneuten Download fortgesetzt. `--restart` berechnet alle Blöcke neu.

Mit `--band-profile rgbnir` fließt zusätzlich B08 tatsächlich in die Textur ein.
Das benötigt ungefähr 35.600 Processing Units und damit mehr als ein
30.000er-Monatskontingent. `full` ergänzt die gültigen Beobachtungen und liegt
bei ungefähr 44.500 Einheiten. Ohne Farbsicherung nutzt `quota` Grün/Rot/NIR mit
drei Eingabebändern und bleibt ebenfalls unter 30.000 Einheiten.

Vor jedem Vollabruf kann die konkrete Schätzung ohne Anmeldung geprüft werden:

```sh
./scripts/preprocess_surface_texture.sh --germany --band-profile rgb --dry-run
```

Grundlage der Schätzung ist die
[offizielle Processing-Unit-Definition](https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Overview/ProcessingUnit.html).

Das verlustfreie Deutschlandarchiv benötigt voraussichtlich rund 55–65 GiB.
Die Pipeline prüft freien Speicher vorab und verlangt bei zu wenig Platz ein
externes Laufwerk. Das App-Datenverzeichnis enthält weiterhin kein RGB, sondern
nur den neutralen Detailkanal.

Die Ausgabe heißt `zN/x_y.surface.z`. Niedrigere Zoomstufen werden aus jeweils
vier Kindkacheln gemittelt; der Shader blendet sie zusätzlich zwischen 20 und
320 m/Pixel weich aus. Das Manifest enthält die klassenabhängigen Gewichte:
Landwirtschaft 100 %, Wald 85 %, Grasland 65 %, Siedlung 42 %, Wasser 0 %.

Unter `MapData/Germany/SurfaceTexture/` entsteht außerdem eine reine
TopoExplorer-Vergleichsgrafik mit 0, 20, 30, 40, 50 und 60 % Modulation. Eine
regelbare Kantenverstärkung hebt kleinräumige Übergänge im Detailkanal hervor.
Die Vergleichsgrafik enthält zusätzlich die echten Vektorstraßen, aber weiterhin
keine Satellitenfarben.

Zusätzlich entsteht
`hannover-check-00-20-30-40-50-60.jpg`. Wenn ein Farbsicherungsarchiv angegeben
ist, zeigt dieses JPEG links den tatsächlich genutzten Sentinel-RGB-Ausschnitt
und rechts alle sechs TopoExplorer-Stärken mit Straßen.

Nach einer Änderung der Vergleichsstärken lässt sie sich ohne erneuten Abruf
aus den vorhandenen Tiles erzeugen:

```sh
./scripts/preprocess_surface_texture.sh --preview-only
```

Die Quartalsmosaike sind seit 2015 weltweit verfügbar und werden aus drei
Monaten Level-2A-Daten mit SCL-Wolkenmaske und erstem Quartil aufgebaut. Technische
Quelle und BYOC-Collection-ID:
[Copernicus Data Space – Sentinel-2 Level-3 Quarterly Mosaics](https://documentation.dataspace.copernicus.eu/Data/SentinelMissions/Sentinel2.html#sentinel-2-level-3-quarterly-mosaics).
