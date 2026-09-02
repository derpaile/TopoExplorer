# TopoExplorer – Bedienungsanleitung

## Installation und erster Start

1. `TopoExplorer.dmg` öffnen.
2. Die App nach „Applications“ ziehen.
3. TopoExplorer starten. Beim ersten Start öffnet sich die Ordnerwahl automatisch.
4. `MapData/Germany` oder den übergeordneten `MapData`-Ordner wählen.

Die Kartendaten bleiben außerhalb der App. Dadurch ist das Programm klein und
eine Karte kann unabhängig aktualisiert werden.

## Kartendaten selbst erzeugen

Die Rohdaten werden wie in `Data/README.md` abgelegt. Im Projektordner genügen
anschließend genau zwei Befehle:

```sh
./scripts/prepare_all.sh
./scripts/build_app.sh
```

Ein abgebrochener Kachellauf kann mit demselben Befehl fortgesetzt werden.

## Karte erkunden

- Ziehen verschiebt die Karte.
- Mausrad oder Trackpad zoomt um den Mauszeiger.
- Doppelklick zoomt hinein.
- `0` zeigt ganz Deutschland; `+` und `−` ändern die Zoomstufe.
- Die Referenzansichten springen zu Harz, Alpen, Küste, Ruhrgebiet oder
  Flachland.
- „Kartendaten wählen“ wechselt zu einem anderen Kachelordner.

Die Kartenleiste passt sich der Fensterbreite an. In schmalen Ansichten bleiben
Ort, Zoom, Flächenanalyse und Landschaftsprofil direkt erreichbar; Export,
Datenatlas, Sammlung, Stil und Hilfe wandern gesammelt in das Menü `…`.

## Tastatur

- `⌘K` öffnet die Stöberpalette für Landschaftsfunde, Datensätze und Werkzeuge.
- `⌘F` sucht Orte oder Koordinaten; `⇧⌘E` zeigt den nächsten Landschaftsfund.
- `⇧⌘D` öffnet den Datenatlas, `⇧⌘M` die Sammlung.
- `⇧⌘A` startet die Flächenanalyse, `⇧⌘P` das Landschaftsprofil.
- `⇧⌘X` exportiert die Karte, `⇧⌘L` blendet die Seitenleiste um.
- `0` passt Deutschland ein; `+` und `−` zoomen.

## Ebenenstapel und Darstellung

Der ruhige Ebenenstapel links ordnet die Karte fachlich: Die hochauflösende
Landoberfläche ist die feste Basis, darunter folgt höchstens eine aktive
Raster-Fachkarte. Namen, Verkehr, Gewässer, Grenzen und Energie bilden
kompakte Orientierungsebenen. Ein Klick auf eine Ebene öffnet rechts ihre
Kontext-Schublade; der Schalter in der Zeile blendet sie direkt ein oder aus.

In der Kontext-Schublade der Landoberfläche sind die 40 Landklassen in
Grundlage, Siedlung, Natur, Landwirtschaft und Wald gegliedert. Ein Klick auf
das Farbfeld öffnet direkt darunter eine schnelle Palette. Haken schalten
einzelne Klassen oder ganze Gruppen zwischen farbiger und ausgegrauter
Darstellung um; die Suche findet beispielsweise Nutzpflanzen und Baumarten
sofort. Historische Zeitstände bleiben eingeklappt verfügbar, die
hochauflösende Gesamtkarte ist der Normalzustand. Das
unveränderliche Profil **Standard · Erststart** stellt exakt die Darstellung
des ersten Starts dieser Version wieder her. Dazu kommen Kulturarten,
Waldarten, Kontrastreich, Satellitisch, Kupferstich, Nordlicht, Pastellfelder
und Bauhaus. Stil-Dateien lassen sich speichern, weitergeben und importieren.

Der Fachkarten-Katalog gruppiert Substrat, Geologie, Reliefform und
Grundwasser. Genau eine Raster-Fachkarte kann aktiv sein; ihre Schublade
enthält Deckkraft, erweiterte Basiskarten-Darstellung, Legende und Quellen.
Straßen, Eisenbahnen, Flüsse, Grenzen und Ortsnamen erscheinen abhängig von der
Zoomstufe. Natur- und Geländenamen besitzen eigene Farben und Schriften;
größere Landschaftsnamen folgen einer leicht gedrehten kartografischen
Ausrichtung.

## Datenatlas

Der Datenatlas ist über das Bücher-Symbol in der Kartenleiste und unten in der
Seitenleiste erreichbar. Er vereint Landbedeckung, Relief, Sentinel-Feinstruktur,
Fachkarten, OpenStreetMap und amtliche BKG-Geonamen. Die Suche berücksichtigt
Quellenname, Thema, Lizenz und Jahr; Themenchips grenzen die Liste ein. Jeder
Eintrag zeigt Rolle, Erfassungsjahr, Maßstab und Nutzungslizenz, verlinkt die
Originalquelle und kann den zugehörigen Karteninhalt direkt einblenden.

Die **Stöberpalette** bündelt diese Quellen mit Landschaftsfunden und zentralen
Werkzeugen. `⌘K` öffnet sie über der Karte; Tippen filtert alle Bereiche
gemeinsam und `Esc` schließt sie wieder.
Mit `↑` und `↓` wandert die hervorgehobene Auswahl durch alle Bereiche; `↩`
öffnet den jeweils gewählten Treffer.

## Suche und Informationen

Die Suche akzeptiert Ortsnamen sowie Koordinaten. Ein Treffer wird direkt
zentriert. Unter dem Mauszeiger zeigt die App – sofern in den Daten vorhanden –
Höhe, Hangneigung, Exposition und Landklasse. Ein einzelner Klick hält den Punkt als Fundstelle fest:
Landoberfläche und aktive Fachklasse bleiben gemeinsam sichtbar, die
EPSG:3035-Koordinate lässt sich kopieren und der Punkt kann zentriert oder als
Fundstelle mit eigenem Namen und einer Beobachtungsnotiz gespeichert werden.
Ein Klick auf das Schließen-Symbol löst die Fundstelle wieder.

Unter **Umgebung lesen** wird aus dem Einzelpunkt ein Landschaftsausschnitt.
Wählbare Kreise von 1, 3 oder 10 Kilometern erscheinen maßstäblich auf der
Karte. Die App beschreibt prägende und begleitende Oberflächen, ihre Anteile,
den Höhenraum, mittlere und maximale Hangneigung, Reliefcharakter, Bevölkerung
und Dichte aus dem 100-m-Zensusraster, die Vielfalt des Mosaiks und – falls aktiv –
die dominierende Fachklasse. Die Auswertung liest lokale Kacheln und benötigt
keinen Onlinedienst. **Namen im Kreis** erschließt außerdem nahe Orte, Gipfel,
Gewässer, Landschaften und Naturgebiete aus dem lokalen Namensindex. Entfernung
und Himmelsrichtung sind direkt lesbar; ein Klick fliegt sanft zum Fund.
Nummerierte Marken und feine Verbindungslinien bilden dieselben Funde an ihren
tatsächlichen Positionen auf der Karte als kleine Fundkonstellation ab.
Beim Überfahren eines Nummernpunkts öffnet sich radial ein kompaktes Schild mit
Name, Typ, Distanz und Richtung; Klick oder Tastaturaktivierung fliegt den Fund an.
Eine animierte **Landschaftsorb** fasst zugleich sämtliche Klassen zu Siedlung,
Landwirtschaft, Wald und Natur zusammen. Ring, Prozentzeile und Zentrum machen
Mischung und dominante Gruppe auf einen Blick vergleichbar.

Die Sammlung unten in der Seitenleiste zeigt die letzten Orte und öffnet eine
vollständige Schublade. Fundstellen mit Punktdaten können dort als **A** und
**B** gewählt werden. Der Vergleich stellt Landoberfläche, Landschaftsgruppe,
Höhe, Hanglage und – sofern vorhanden – Fachklassen nebeneinander. Wurde vor dem Merken
die Umgebung gelesen, bleiben außerdem Radius, farbiges Oberflächenmosaik,
prägende Klasse, Vielfalt, Höhenraum, Relief, Bevölkerung und nahe Namen erhalten und werden als zwei
Landschaftsbilder verglichen. Ältere einfache Lesezeichen und Punktfundstellen
bleiben vollständig nutzbar.

**GeoJSON exportieren** schreibt die gesamte Sammlung als offenes Feldbuch.
Jede Fundstelle besitzt eine standardkonforme WGS84-Punktgeometrie für QGIS,
MapLibre und andere Geowerkzeuge. Zusätzlich bleiben die exakten
EPSG:3035-Meterkoordinaten, Notizen, Punktwerte, Geländeableitungen,
Umgebungsmosaike, Bevölkerungswerte und alle im
Datenatlas dokumentierten Quellen samt Lizenz im Dokument erhalten.
**Importieren** liest TopoExplorer-Feldbücher verlustfrei und übernimmt auch
Punkte aus gewöhnlichen GeoJSON-FeatureCollections. Bereits vorhandene
Fundstellen werden beim Zusammenführen nicht dupliziert.

## Landschaftsprofil

Das Profilsymbol in der Kartenleiste aktiviert das Linienwerkzeug. Von **A**
nach **B** ziehen: Die App tastet die Strecke mit höchstens 240 Punkten aus den
feinsten verfügbaren Kacheln ab. Das Ergebnis verbindet Höhenkurve,
Gesamtanstieg und -abstieg mit einem farbigen Band der durchquerten
Landoberflächen. Ist eine Fachkarte aktiv, wird zusätzlich die Zahl ihrer
entlang der Linie vorkommenden Klassen angegeben. Die Profillinie bleibt beim
Verschieben und Zoomen lagegenau auf der Karte.

## Gesamt-Landbedeckung

Die Gesamtkarte verbindet ESA WorldCover 2021, JRC EUCROPMAP 2018 und die
ForestPaths-Baumgattungen 2020. Land Cover DE 2015 ergänzt ausschließlich
Nadelwald-Offenflächen. Unterschieden werden unter anderem Siedlungsdichte,
Naturflächen, 20 Landwirtschaftsklassen und neun Waldklassen. Es ist eine
artenreiche Ansicht, kein Zeitvergleich.

## Export

Der Export erzeugt nur den gewählten Ausschnitt. `2×` und `4×` werden mit
feineren Raster- und Vektorkacheln neu gerendert; sie sind keine vergrößerten
Bildschirmfotos. Maßstab, Quellen und vollständige Stilinformationen werden
eingebettet. Die Grenze liegt bei 16.384 Pixeln je Kante und 32 Megapixeln.
Eine vollständige Deutschland-Mega-PNG ist weder nötig noch vorgesehen.

## Fehlerbehebung

- „manifest.json fehlt“: den Ordner `MapData/Germany` wählen.
- „Kachelerzeugung nicht abgeschlossen“: den Aufbereitungsbefehl erneut
  starten und danach die Datenprüfung ausführen.
- Leere Karte: prüfen, ob `manifest.json` und die Unterordner `z0`, `z1`, …
  gemeinsam im gewählten Ordner liegen.
- Kein dauerhafter Ordnerzugriff: „Kartendaten wählen“ erneut verwenden.
- Darstellungsfehler: `./scripts/verify_image_quality.sh` im Projekt ausführen.

## Datenschutz

TopoExplorer arbeitet lokal. Kartendaten, Suchverlauf, Stile und Exporte
werden nicht automatisch hochgeladen. Externe Dienste sind für die
Kartendarstellung nicht erforderlich.

Quellen und Lizenzhinweise stehen in `Datenquellen.md` und sichtbar in Karte
und Export. Exporte mit der DLR-Landbedeckung 2015 sind wegen `CC BY-NC 4.0`
nicht für kommerzielle Nutzung freigegeben.
