# Satellitenbasierte Oberflächentextur

TopoExplorer übernimmt aus dem Copernicus Sentinel-2 Level-3 Quarterly Mosaic
ausschließlich lokale Helligkeitsstruktur. Klassen und Farben stammen weiterhin
vollständig aus der Landcover-Karte. Es wird weder ein RGB-Satellitenbild erzeugt
noch gespeichert.

## Hannover-Proof-of-Concept

Für den direkten Copernicus-Abruf werden OAuth-Zugangsdaten aus dem CDSE-Dashboard
als Umgebungsvariablen benötigt:

```sh
export CDSE_CLIENT_ID="…"
export CDSE_CLIENT_SECRET="…"
./scripts/preprocess_surface_texture.sh --quarter 2025-Q2
```

Der Standardausschnitt umfasst Hannover und Umgebung. Der Abruf erfolgt für
B02, B03, B04, B08 und die Zahl gültiger Beobachtungen einzeln und nur im
Arbeitsspeicher. Alternativ können bereits vorhandene Einzelband-Raster benutzt
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

Die Ausgabe heißt `zN/x_y.surface.z`. Niedrigere Zoomstufen werden aus jeweils
vier Kindkacheln gemittelt; der Shader blendet sie zusätzlich zwischen 20 und
320 m/Pixel weich aus. Das Manifest enthält die klassenabhängigen Gewichte:
Landwirtschaft 100 %, Wald 85 %, Grasland 65 %, Siedlung 42 %, Wasser 0 %.

Unter `MapData/Germany/SurfaceTexture/` entsteht außerdem eine reine
TopoExplorer-Vergleichsgrafik mit 0, 20, 30, 40 und 50 % Modulation. Sie enthält
nur Klassenfarben plus Graustufen-Detail, keine Satellitenfarben.

Nach einer Änderung der Vergleichsstärken lässt sie sich ohne erneuten Abruf
aus den vorhandenen Tiles erzeugen:

```sh
./scripts/preprocess_surface_texture.sh --preview-only
```

Die Quartalsmosaike sind seit 2015 weltweit verfügbar und werden aus drei
Monaten Level-2A-Daten mit SCL-Wolkenmaske und erstem Quartil aufgebaut. Technische
Quelle und BYOC-Collection-ID:
[Copernicus Data Space – Sentinel-2 Level-3 Quarterly Mosaics](https://documentation.dataspace.copernicus.eu/Data/SentinelMissions/Sentinel2.html#sentinel-2-level-3-quarterly-mosaics).
