# TopoExplorer-Vektorkacheln (`TVT1`)

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
| Layer: Straße 1, Bahn 2, Wasserlauf 3, Grenze 4 | `u8` |
| Untertyp, ab 1; Namen stehen im Manifest | `u8` |
| minimale Zoomstufe | `u8` |
| Flags: Brücke 1, Tunnel 2 | `u8` |
| Punktanzahl | `u16` |
| UTF-8-Namenslänge | `u16` |
| Punkte `(x, y)` | je `i16, i16` |
| optionaler Name | UTF-8 |

## Ortsrecord

| Feld | Typ |
|---|---:|
| Ortsart, ab 1; Namen stehen im Manifest | `u8` |
| minimale Zoomstufe | `u8` |
| reserviert | `u16` |
| Position `(x, y)` | `i16, i16` |
| Bevölkerung; 0 bedeutet unbekannt | `u32` |
| UTF-8-Namenslänge | `u16` |
| Name | UTF-8 |

`places-index.json.z` ist ein zlib-komprimiertes JSON-Dokument für Suche und
direktes Anspringen. Jedes Array folgt den Feldern
`name, kind, population, x, y, minZoom`; `x/y` sind EPSG:3035-Koordinaten.
