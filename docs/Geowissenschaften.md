# Geowissenschaftliche Produktfamilie

Die Produktfamilie ergänzt die unveränderte Landbedeckung um zwei unabhängige
Ebenen:

1. **Oberflächensubstrat** – bundesweit BÜK250, präzise Landesdaten als Override.
2. **Oberflächennahe Geologie** – bundesweit GÜK250, etwa dGK25 in Bayern als Override.

## Ausgelieferter amtlicher Bundesbestand

```sh
./scripts/fetch_bgr_substrate.sh
./scripts/fetch_bgr_geology.sh
```

Die Spezialimporte erzeugen fachlich ehrliche 80-m-Master-COGs und Kacheln bis
z5; z6–z8 verwenden die passende Elternkachel. Enthalten sind BÜK250 V6.0 und
GÜK250.

Die beiden Flächenprodukte besitzen je ein Klassenraster und ein Qualitätsraster.
Qualitätswert `0` bedeutet „keine Quelle“, `1…n` verweist auf den entsprechenden
Eintrag in `thematicRasters[].sources`. Damit zeigt die App am Mauszeiger nicht
nur die Klasse, sondern auch Quelle und Erfassungsmaßstab. Ein 10-m-Ausgaberaster
erhöht nicht die fachliche Genauigkeit einer Karte im Maßstab 1:250.000.

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
