# TopoExplorer-Vektorkacheln (`TVT1` und `TVT2`)

Die Pipeline `germany_vectors.py` erzeugt dieselben Zoomstufen und
Kachelkoordinaten wie die Rasterkarte. Dateien fehlen absichtlich, wenn eine
Kachel leer ist.

## Ablage

```text
MapData/Germany/Vectors/
├── vector-manifest.json
├── places-index.json.z
└── z{z}/{x}_{y}.vector.z
```

Alle `.z`-Dateien sind als Ganzes mit zlib komprimiert. Ganzzahlen sind
little-endian. Tile-lokale Koordinaten verwenden `extent = 8192`: `(0, 0)` ist
die linke obere und `(8192, 8192)` die rechte untere Kante. Linien dürfen wegen
des 8-Pixel-Clipping-Puffers Werte von `-128` bis `8320` besitzen.

## Kachelkopf

| Feld | Typ |
|---|---:|
| Magic `TVT1` | 4 Bytes |
| Formatversion | `u16` |
| Extent | `u16` |
| Puffer | `u16` |
| Linienanzahl | `u32` |
| Ortsanzahl | `u32` |

Danach folgen zuerst alle Linien und anschließend alle Orte.

## Linienrecord

| Feld | Typ |
|---|---:|
| Layer: Straße 1, Bahn 2, Wasserlauf 3, Grenze 4, Energie 8 | `u8` |
| Untertyp, ab 1; Namen stehen im Manifest | `u8` |
| minimale Zoomstufe | `u8` |
| Flags: Brücke 1, Tunnel 2 | `u8` |
| Punktanzahl | `u16` |
| UTF-8-Namenslänge | `u16` |
| Punkte `(x, y)` | je `i16, i16` |
| optionaler Name | UTF-8 |

## Namensrecord

| Feld | Typ |
|---|---:|
| Namensart, ab 1; Orte 1–6, Natur- und Geländenamen 7–12; Bezeichnungen stehen im Manifest | `u8` |
| minimale Zoomstufe | `u8` |
| reserviert | `u16` |
| Position `(x, y)` | `i16, i16` |
| Bevölkerung; bei Natur- und Geländenamen 0 | `u32` |
| UTF-8-Namenslänge | `u16` |
| Name | UTF-8 |

`places-index.json.z` ist ein zlib-komprimiertes JSON-Dokument für Orts- und Geonamensuche und
direktes Anspringen. Jedes Array folgt den Feldern
`name, kind, population, x, y, minZoom`; `x/y` sind EPSG:3035-Koordinaten.

Der Energielayer verwendet die Untertypen 1–3 für 380-, 220- und 110-kV-Leitungen.
Die Untertypen 4–8 sind punktförmige Marker für Umspannwerke, Transformatoren,
Windenergieanlagen, Photovoltaik und konventionelle Erzeuger. Punktmarker werden
als Record mit zwei identischen Koordinaten gespeichert und vom Renderer als
kartografische Symbole gezeichnet.

## TVT2-Fachobjekte

TVT2 bleibt zu TVT1 abwärtskompatibel und ersetzt nur Magic/Version durch
`TVT2`/`2`. Hinter der Ortsanzahl steht zusätzlich eine Fachobjektanzahl als
`u32`. Die bisherigen Linien- und Ortsrecords bleiben bytegleich; anschließend
folgen dynamisch viele Fachobjekte.

| Feld | Typ |
|---|---:|
| Layer: Bergbau 5, Kohlenwasserstoffe 6, Pipeline 7 | `u8` |
| Untertyp | `u8` |
| Geometrie: Punkt 1, Linie 2, Polygon 3 | `u8` |
| minimale Zoomstufe | `u8` |
| Punktanzahl | `u16` |
| UTF-8-Namenslänge | `u16` |
| JSON-Attributlänge | `u16` |
| Punkte `(x, y)` | je `i16, i16` |
| Name und unveränderte Attribute | UTF-8 |

Der Swift-Decoder reserviert keine feste Layerzahl mehr. Punkte werden als
Symbole, Linien und Polygonränder als thematisch gefärbte Segmente gerendert.
