# Datengrundlagen einrichten

TopoExplorer liefert aus Größen- und Lizenzgründen keine fertige Deutschlandkarte
im Git-Repository aus. Die App liest ein lokal erzeugtes Kachelverzeichnis unter
`MapData/Germany`. Dieses Dokument beschreibt, welche Ausgangsdaten dafür nötig
sind, wo sie liegen müssen und was die Skripte daraus erzeugen.

## Welcher Umfang ist nötig?

| Umfang | Manuell benötigte Quellen | Ergebnis |
|---|---|---|
| **Basiskarte** | DLR Land Cover DE, Höhenmodell, OSM Deutschland-PBF | 40 Landklassen, Relief, Straßen, Bahn, Gewässer, Grenzen, Orte und Energie |
| **Mit Bevölkerung** | Basiskarte plus 100-m-Bevölkerungsraster | zusätzlich Einwohner, Dichte, Flächen- und Umgebungsanalyse |
| **Mit Fachkarten** | Basiskarte plus BGR-/Landesdaten | zusätzlich Substrat, Geologie, Reliefform und Grundwasser |
| **Mit Oberflächentextur** | Basiskarte plus CDSE-Zugang | zusätzlich Sentinel-2-Feinstruktur in hohen Zoomstufen |

Für einen ersten Start genügt die **Basiskarte**. Bevölkerung, Fachkarten und
Sentinel-Textur sind optional und können später ergänzt werden.

## Platz- und Zeitbedarf

Der Deutschlandaufbau ist kein kleiner Beispieldatensatz:

| Bestandteil | Größenordnung |
|---|---:|
| DLR-ZIP / entpacktes GeoTIFF | ca. 244 MiB / 640 MiB |
| aktuelles OSM-Deutschland-PBF | ca. 4,5 GB |
| zugeschnittenes GMTED-GeoTIFF | ca. 30–50 MiB |
| fertiges `MapData/Germany` | derzeit ca. 9–10 GB |
| empfohlener freier Speicher vor dem Start | mindestens 20 GB |

WorldCover, EUCROPMAP und ForestPaths werden nacheinander verarbeitet und nach
der Integration wieder entfernt. Die voreingestellte Arbeitsgrenze beträgt
8 GB. Der Lauf kann je nach Internetverbindung und Mac mehrere Stunden dauern;
ein Abbruch ist unkritisch, weil abgeschlossene Stufen protokolliert werden.

## Die drei Pflichtquellen

### 1. DLR Land Cover DE 2015

**Zweck:** Das 10-m-Raster legt den exakten Deutschlandausschnitt fest und
ergänzt die Klasse „Nadelwald-Offenfläche“. Die übrige 40-Klassen-Karte entsteht
aus den automatisch geladenen Quellen weiter unten.

- Produkt: [Land Cover DE – Sentinel-2 – Germany, 2015](https://geoservice.dlr.de/data-assets/1ccmlap3mn39.html)
- Direktdownload: [Land_Cover_DE_2015_v1.zip](https://download.geoservice.dlr.de/LCC_DE/files/Land_Cover_DE_2015_v1.zip)
- räumliche Auflösung: 10 m
- KBS: EPSG:3035
- Lizenz: CC BY-NC 4.0
- erwartete Datei: `Data/Raw/LandCover/Land_Cover_DE_2015.tif`

```sh
mkdir -p Data/Raw/LandCover
curl -fL --continue-at - \
  -o Data/Raw/LandCover/Land_Cover_DE_2015_v1.zip \
  https://download.geoservice.dlr.de/LCC_DE/files/Land_Cover_DE_2015_v1.zip
unzip -o -j Data/Raw/LandCover/Land_Cover_DE_2015_v1.zip \
  -d Data/Raw/LandCover
```

Wegen der nichtkommerziellen Lizenz dürfen Kartenexporte, in denen diese Quelle
verwendet wird, nicht kommerziell genutzt werden.

### 2. GMTED2010 Mean, 7,5 Bogensekunden

**Zweck:** Höhenwerte, Hangneigung, Exposition, Relief und Profile. Das
Quellmodell hat etwa 250 m Rasterweite. Die App speichert das Relief in einem
100-m-Abtastraster; dadurch entsteht keine zusätzliche fachliche Detailtiefe.

- Produkt: [USGS/NGA GMTED2010](https://www.usgs.gov/centers/eros/science/usgs-eros-archive-digital-elevation-global-multi-resolution-terrain-elevation)
- Auswahl: **Mean**, **7.5 arc-seconds**, **GeoTIFF**
- sinnvoller Ausschnitt: ungefähr 4,32–16,99° Ost und 46,17–55,74° Nord
- KBS: üblicherweise EPSG:4326; andere Raster-KBS werden beim Aufbau reprojiziert
- NoData: sollte im Raster ausgewiesen sein, empfohlen `-32768`
- erwartete Datei: `Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff`

USGS stellt das Produkt über EarthExplorer sowie als globale ESRI-ArcGrid-Datei
bereit. Für TopoExplorer ist ein auf Deutschland zugeschnittener GeoTIFF-Export
deutlich platzsparender. Der Dateiname ist lokal frei wählbar, wenn er mit
`./scripts/prepare_all.sh --dem /pfad/zum/dem.tif` übergeben wird; ohne Argument
gilt der oben genannte Standardpfad.

Ein anderes Höhenmodell ist zulässig, sofern Rasterio es lesen kann und es
Höhenwerte in Metern enthält. Die Herkunft und Lizenz müssen dann im eigenen
Projekt dokumentiert werden.

### 3. OpenStreetMap Deutschland-PBF

**Zweck:** Straßen, Bahnlinien, Fließgewässer, Verwaltungsgrenzen, Orte,
Stromleitungen, Umspannwerke, Transformatoren und Erzeugungsanlagen.

- Produktseite: [Geofabrik Deutschland](https://download.geofabrik.de/europe/germany.html)
- Direktdownload: [germany-latest.osm.pbf](https://download.geofabrik.de/europe/germany-latest.osm.pbf)
- Lizenz: Open Database License 1.0
- erwartete Datei: `Data/Raw/OSM/germany-latest.osm.pbf`

```sh
mkdir -p Data/Raw/OSM
curl -fL --continue-at - \
  -o Data/Raw/OSM/germany-latest.osm.pbf \
  https://download.geofabrik.de/europe/germany-latest.osm.pbf
```

`scripts/prepare_osm_extracts.sh` erzeugt daraus automatisch:

```text
Data/Raw/OSM/railways.geojson   Bahngeometrien
Data/Raw/OSM/places.geojson     Orte samt Name, Typ und ggf. Einwohnerzahl
```

Diese beiden GeoJSON-Dateien sind **keine zusätzlichen Downloads**. Vorhandene
Dateien werden wiederverwendet; nach einem Austausch des PBF sollten sie
gelöscht und neu erzeugt werden.

## Automatisch geladene Quellen

Diese Dateien müssen nicht vorab beschafft werden:

| Quelle | Verwendung | Verhalten |
|---|---|---|
| [ESA WorldCover 2021](https://esa-worldcover.org/) | Grundbedeckung in 10 m | passende 3°-Kacheln werden einzeln geladen |
| [JRC EUCROPMAP 2018](https://data.jrc.ec.europa.eu/dataset/15f86c84-eae1-4723-8e00-c1b35c8f56b9) | Kulturarten | Kandidaten werden einzeln integriert |
| [ForestPaths Tree Genus Map 2020](https://zenodo.org/records/13341104) | Baumgattungen | Archive werden spaltenweise integriert |
| [BKG GN250](https://gdz.bkg.bund.de/index.php/default/geographische-namen-1-250-000-gn250.html) | Berge, Landschaften, Gewässer, Naturgebiete, Inseln und Höhlen | CSV und amtliche Dokumentation werden automatisch geladen |

Die ersten drei Quellen landen nur vorübergehend in
`.build/landcover-10m/downloads`. Standardmäßig wird jede Quelldatei nach ihrer
Integration gelöscht. Mit `--keep-downloads` bleiben sie für Diagnosezwecke
erhalten.

## Optionale Bevölkerung

Die App funktioniert ohne Bevölkerungsdaten. Dann fehlen nur Einwohner-,
Dichte- und darauf aufbauende Umgebungswerte.

Als Quelle eignen sich die amtlichen
[Zensus-Gitterdaten](https://www.destatis.de/DE/Themen/Gesellschaft-Umwelt/Bevoelkerung/Zensus2022/_inhalt.html).
Die aktuelle Pipeline erwartet ein bereits rasterisiertes GeoTIFF mit folgenden
Eigenschaften:

| Eigenschaft | Anforderung |
|---|---|
| Pfad | `Data/Raw/Population/Zensus_Bevoelkerung_100m-Gitter.tif` |
| KBS | EPSG:3035 |
| Zellgröße | quadratisch, üblicherweise 100 m |
| Ausrichtung | nordorientiert, nicht gedreht |
| Zellwert | Einwohnerzahl, ganzzahlig und nicht negativ |
| NoData | negativer Wert oder korrektes NoData-Attribut |

Die Zensus-Portale liefern je nach Jahr CSV-Gitterdaten. Deren Zellkennungen
beziehen sich auf das INSPIRE-100-m-Gitter in EPSG:3035; sie müssen vor dem
TopoExplorer-Lauf in ein GeoTIFF rasterisiert werden. Ein beliebiger Dateiname
ist möglich, wenn er explizit übergeben wird:

```sh
./scripts/preprocess_population.sh /pfad/zum/bevoelkerung-100m.tif
```

Liegt die Standarddatei beim Aufruf von `prepare_all.sh` nicht vor, wird dieser
Schritt mit einem Hinweis übersprungen; die Basiskarte bleibt vollständig
nutzbar.

## Erwartete Eingabestruktur

Vor dem Basisaufbau sollte der relevante Teil von `Data/Raw` so aussehen:

```text
Data/Raw/
├── Elevation/
│   └── gmted2010_mean_7p5arcsec.tiff       Pflicht
├── LandCover/
│   └── Land_Cover_DE_2015.tif              Pflicht
├── OSM/
│   ├── germany-latest.osm.pbf              Pflicht
│   ├── railways.geojson                    wird erzeugt
│   └── places.geojson                      wird erzeugt
├── BKG/
│   └── gn250/GN250.csv                     wird geladen
└── Population/
    └── Zensus_Bevoelkerung_100m-Gitter.tif optional
```

Der Vorab-Check zeigt den Zustand ohne Änderungen an:

```sh
./scripts/check_source_data.sh
```

## Verarbeitung starten

```sh
./scripts/prepare_all.sh
```

Der Befehl führt in dieser Reihenfolge aus:

1. lokale Python-Umgebung und Rasterbibliotheken einrichten,
2. WorldCover, EUCROPMAP und ForestPaths herunterladen und integrieren,
3. Reliefkacheln aus dem Höhenmodell erzeugen,
4. GN250 laden und OSM-Bahn-/Ortsdateien ableiten,
5. Vektor- und Suchkacheln erzeugen,
6. die fertige Karte als `MapData/Germany` aktivieren,
7. optional das Bevölkerungsraster kacheln,
8. vorhandene Bestandteile prüfen.

Ein vorhandenes `MapData/Germany` wird vor der Aktivierung mit Zeitstempel als
`MapData/Germany-50m-backup-…` gesichert. Ein abgebrochener Neuaufbau unter
`MapData/Germany-10m` kann mit demselben Befehl fortgesetzt werden.

## Erzeugte Dateien

```text
MapData/Germany/
├── manifest.json                    KBS, Grenzen, Zoomstufen, Klassen, Quellen
├── z0/ … z8/                        Land- und Reliefkacheln
│   ├── {x}_{y}.landrich.z           512×512 Landklassen, zlib
│   └── {x}_{y}.elev.z               Höhenwerte mit Überlappungsrand, zlib
├── Vectors/
│   ├── vector-manifest.json         Ebenen, Formate, Quellsignaturen
│   ├── places-index.json.z          vollständiger Suchindex
│   └── z*/{x}_{y}.tvt.z             Linien, Orte und Energieobjekte
└── Analysis/                        nur bei optionaler Bevölkerung
    ├── population.json              Rastergeometrie, Quelle und Prüfsummen
    └── *.population.u16.z           512×512 Einwohnerkacheln
```

`manifest.json` ist der Einstiegspunkt der App. Wird ein anderer Kartenordner
verwendet, muss dieser Ordner direkt das Manifest und die Zoomordner enthalten.

## Optionale geowissenschaftliche Fachkarten

Nach dem Basisaufbau können die amtlichen Bundesprodukte einzeln ergänzt werden:

```sh
./scripts/fetch_bgr_substrate.sh
./scripts/fetch_bgr_geology.sh
./scripts/fetch_bgr_geomorphography.sh
./scripts/fetch_bgr_groundwater.sh
```

Enthalten sind BÜK250 V6.0, GÜK250, GMK1000R V2.0 und GWS1000_250 V1.0.
Genauigkeit, Qualitätsraster und Landes-Overrides sind in
[Geowissenschaften.md](Geowissenschaften.md) beschrieben.

## Optionale Sentinel-Oberflächentextur

Die Oberflächentextur benötigt einen eigenen Copernicus-Data-Space-Zugang und
ist wegen Quoten und Datenmenge kein Bestandteil des Basisaufbaus. Einrichtung,
Schlüsselbundspeicherung, Archivoptionen und Kostenabschätzung stehen in
[Oberflaechentextur.md](Oberflaechentextur.md).

## Prüfung und typische Fehler

```sh
./scripts/verify_vectors.sh
.venv/bin/python preprocess/verify_tiles.py MapData/Germany
```

Mit vorhandener Bevölkerung führt `prepare_all.sh` zusätzlich die vollständige
Laufzeit- und Referenzbildprüfung aus.

| Meldung | Ursache / Lösung |
|---|---|
| `Quelldatei fehlt` | Pfad und exakten Dateinamen mit `check_source_data.sh` prüfen |
| `osmium-tool fehlt` | `brew install osmium-tool` ausführen |
| `Bevölkerungsraster muss EPSG:3035 sein` | Raster vorab nach EPSG:3035 reprojizieren |
| Arbeitsgrenze überschritten | mehr freien Speicher schaffen oder bewusst `--max-work-gb` erhöhen |
| weniger als 750 MB frei | der Lauf stoppt zum Schutz des Datenträgers; Speicher freigeben |
| `.incomplete` vorhanden | denselben Vorbereitungslauf erneut starten; nicht manuell aktivieren |

## Quellen und Lizenzen

| Quelle | Lizenz / Nutzungshinweis |
|---|---|
| ESA WorldCover 2021 | CC BY 4.0 |
| JRC EUCROPMAP 2018 | European Commission reuse notice |
| ForestPaths European Tree Genus Map 2020 | CC BY 4.0, Early-Access-Datensatz |
| DLR Land Cover DE 2015 | CC BY-NC 4.0 |
| USGS/NGA GMTED2010 | öffentlich verfügbar; Produktmetadaten beachten |
| OpenStreetMap | ODbL 1.0, © OpenStreetMap-Mitwirkende |
| BKG GN250 | Datenlizenz Deutschland – Namensnennung – Version 2.0, `© BKG 2026` |
| Zensus-Gitterdaten | Datenlizenz des gewählten Jahrgangs und Quellenvermerk beachten |
| BGR-Produkte | jeweilige amtliche Produktlizenz und Quellenangabe beachten |

Quellen- und Lizenzangaben werden in der interaktiven Karte, in Exporten und in
den Manifesten mitgeführt. Bei eigenen oder ausgetauschten Quellen müssen diese
Angaben entsprechend angepasst werden.
