# Harz-Landbedeckung in 10 m

Eigenständiger Kartenprototyp ohne OSM, Straßenvektoren oder Änderungen am
Hauptprojekt. Das feste Testgebiet umfasst Goslar, Brocken, Ilsenburg und
Wernigerode (`10.35–11.08° E`, `51.60–52.02° N`).

## Ergebnis

- `output/harz-landcover-10m.tif`: gemeinsame Klasse je 10-m-Zelle
- `output/harz-source-10m.tif`: Herkunft der jeweils sichtbaren Klasse
- `output/harz-overview.png`: gesamtes Testgebiet
- `output/harz-nordharz.png`: Landwirtschaft und Siedlungen am Nordrand
- `output/harz-brocken.png`: Wald und Offenflächen am Brocken
- `output/manifest.json`: Klassen, Flächenanteile, Quellen und Dateigrößen
- `index.html`: lokale Kartenansicht mit vollständiger Legende

## Erzeugen

```sh
./scripts/prepare_harz_landcover.sh
```

Standardmäßig werden nur vier kleine EUCROPMAP-Kacheln, eine WorldCover-Kachel
und ein ForestPaths-Archiv geladen. Nach erfolgreicher Verarbeitung werden die
Downloads wieder entfernt. Die Pipeline stoppt, sobald Arbeitsdaten und
Ergebnisse zusammen 6.000 MB überschreiten.

Zum Behalten der Downloads:

```sh
./scripts/prepare_harz_landcover.sh --keep-downloads
```

## Entscheidungsregeln

1. ESA WorldCover 2021 bildet die neue, flächendeckende Grundlage.
2. JRC EUCROPMAP 2018 verfeinert Ackerflächen in konkrete Kulturarten.
3. ForestPaths 2020 verfeinert bestätigten Wald in Baumgattungen.
4. Die alte 2015-Messung wird ausschließlich als Zusatzbeleg für
   `Nadelwald-Offenfläche` verwendet.
5. Wasser und Siedlung werden nie durch Landwirtschaft oder Baumarten
   überschrieben.

`Nadelwald-Offenfläche` beschreibt nur die Kombination „2015 Nadelwald, 2021
keine Baumdecke“. Sie behauptet keine Ursache.

## Quellen

- ESA WorldCover 2021 v200, CC BY 4.0
- JRC EUCROPMAP 2018, European Commission reuse notice
- ForestPaths European Tree Genus Map 2020, Early Access, CC BY 4.0
- lokale Landbedeckung Deutschland 2015 als ergänzender Herkunftsbeleg

