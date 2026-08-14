# Datenquellen und Lizenzen

Die App selbst enthält keine Kartendaten. Lokal erzeugte Karten verwenden:

- ESA WorldCover 2021: Grundbedeckung in 10 m, CC BY 4.0.
- JRC EUCROPMAP 2018: Kulturarten in 10 m, European Commission reuse notice.
- ForestPaths European Tree Genus Map 2020: Baumgattungen in 10 m, Early-Access-Datensatz, CC BY 4.0.
- Landbedeckung 2015: DLR/EOC, DOI `10.15489/1ccmlap3mn39`, CC BY-NC 4.0; wird nur zur Klasse „Nadelwald-Offenfläche“ verwendet.
- Höhenmodell: USGS/NGA, GMTED2010 Mean, öffentlich verfügbar; Einzelheiten stehen in den mitgelieferten Quelldaten-Metadaten.
- Straßen, Eisenbahnen, Fließgewässer, Grenzen und Orte: © OpenStreetMap-Mitwirkende, Open Database License 1.0.
- Stromnetze, Umspannwerke, Transformatoren und Erzeugungsanlagen: © OpenStreetMap-Mitwirkende, Open Database License 1.0; Klassifikation anhand der OSM-Tags `power`, `voltage`, `generator:source` und `plant:source`.
- Berge, Landschaften, Gewässer-, Naturgebiets-, Insel- und Höhlennamen: Bundesamt für Kartographie und Geodäsie (BKG), „Geographische Namen 1:250 000 (GN250)“, Datenlizenz Deutschland – Namensnennung – Version 2.0 (`DL-DE/BY-2.0`), Quellenvermerk `© BKG 2026`.
- Oberflächensubstrat: BGR BÜK250 V6.0; Landes-Overrides nur gemäß ihrer ausgewiesenen Lizenz.
- Oberflächensubstrat: BGR BÜK250 V6.0 plus BÜK250-Datenbank V1.0;
  die Zuordnung erfolgt über `GEN_ID` und die Hierarchie des Bodenausgangsgesteins.
- Oberflächennahe Geologie: BGR GÜK250; in Bayern optional dGK25.
- Geomorphographische Einheiten: BGR GMK1000R V2.0, 250-m-Raster,
  Maßstab 1:1.000.000; Datenquelle: GMK1000R V2.0, (C) BGR, Hannover, 2006.
- Grundwasserflurabstand: BGR GWS1000_250 V1.0, 250-m-Raster,
  Maßstab 1:1.000.000; Datenquelle: GWS1000_250 V1.0, (c) BGR, Hannover, 2015.

Links:

- https://geoservice.dlr.de/data-assets/1ccmlap3mn39.html
- https://esa-worldcover.org/
- https://data.jrc.ec.europa.eu/dataset/15f86c84-eae1-4723-8e00-c1b35c8f56b9
- https://zenodo.org/records/13341104
- https://www.openstreetmap.org/copyright
- https://osmfoundation.org/wiki/Licence/Attribution_Guidelines
- https://gdz.bkg.bund.de/index.php/default/geographische-namen-1-250-000-gn250.html
- https://www.bgr.bund.de/DE/Themen/Boden/Projekte/Informationsgrundlagen-laufend/BUEK250/BUEK250.html
- https://www.bgr.bund.de/DE/Themen/Sammlungen-Grundlagen/GG_geol_Info/Karten/Deutschland/GUEK250/guek250_inhalt.html
- https://numis.niedersachsen.de/trefferanzeige?docuuid=60ab5e4e-9493-44b0-9cae-d9ce603de742
- https://gdk.gdi-de.org/geonetwork/srv/api/records/33b088ba-49e9-4186-a9ef-80dee2f92586

Die Quellen- und Lizenznennungen bleiben in der interaktiven Karte und in
PNG-Exporten sichtbar; vollständige Angaben liegen außerdem in den
PNG-Metadaten. Wegen `CC BY-NC 4.0` dürfen Exporte mit der
2015-Landbedeckung nicht kommerziell genutzt werden.
