# Geowissenschaftliche Produktfamilie

Die Produktfamilie ergänzt die unveränderte Landbedeckung um vier unabhängige
Ebenen:

1. **Oberflächensubstrat** – bundesweit BÜK250, präzise Landesdaten als Override.
2. **Oberflächennahe Geologie** – bundesweit GÜK250, etwa dGK25 in Bayern als Override.
3. **Geomorphographische Einheiten** – bundesweit GMK1000R V2.0 mit 25 Reliefklassen.
4. **Grundwasserflurabstand** – bundesweit GWS1000_250 V1.0 mit fünf Grundwasserstufen.

## Ausgelieferter amtlicher Bundesbestand

```sh
./scripts/fetch_bgr_substrate.sh
./scripts/fetch_bgr_geology.sh
./scripts/fetch_bgr_geomorphography.sh
./scripts/fetch_bgr_groundwater.sh
```

Die Spezialimporte erzeugen fachlich ehrliche Master-COGs und Kacheln nur bis
zur Auflösung der Quelle; feinere Zoomstufen verwenden die passende
Elternkachel. Enthalten sind BÜK250 V6.0, GÜK250, GMK1000R V2.0 und
GWS1000_250 V1.0. Der GMK1000R-Import lädt das amtliche 250-m-Raster selbst,
übernimmt die 25 Klassen
und Farben der BGR-Legende und projiziert es nach EPSG:3035.
Der GWS1000_250-Import übernimmt entsprechend die fünf veröffentlichten
Grundwasserstufen samt amtlicher Farbskala.

Die Flächenprodukte besitzen je ein Klassenraster und ein Qualitätsraster.
Qualitätswert `0` bedeutet „keine Quelle“, `1…n` verweist auf den entsprechenden
Eintrag in `thematicRasters[].sources`. Damit zeigt die App am Mauszeiger nicht
nur die Klasse, sondern auch Quelle und Erfassungsmaßstab. Ein feineres
App-Kachelraster erhöht nicht die fachliche Genauigkeit der Quellkarte.

## Raster-ETL

```sh
cp preprocess/geoscience_config.example.json preprocess/geoscience_config.json
# Lokale Pfade, Layer und Klassifikationsmuster prüfen.
./scripts/preprocess_geoscience.sh
```

Die Pipeline archiviert alle Quellattribute unverändert in EPSG:3035-GeoPackages,
rasterisiert Quellen von grob nach präzise, schreibt 10-m-COG-Master und erzeugt
die z0–z8-Appkacheln mit `Resampling.mode`. Ergebnisse:

```text
MapData/Germany/
├── Intermediate/Geoscience/{product}.gpkg
├── Masters/Geoscience/{product}-10m.cog.tif
├── Masters/Geoscience/{product}-quality-10m.cog.tif
└── z{z}/{x}_{y}.{substrate|geology}[.quality].z
```

Die Beispielklassifikation arbeitet absichtlich über überprüfbare reguläre
Ausdrücke. Vor einem Produktionslauf müssen die tatsächlichen Attributtabellen
der heruntergeladenen Versionen geprüft und die Muster angepasst werden.
Nicht zuordenbare Einheiten bleiben Klasse `0`; sie werden niemals geraten.
Eine Quelle kann optional `downloadURL` und `sha256` erhalten; ohne amtliche,
stabile Direktadresse erwartet die Pipeline bewusst eine lokal geprüfte Datei.
