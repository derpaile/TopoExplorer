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

## Darstellung

Im rechten Bereich können Landklassenfarben, Relief und verfügbare
Vektorebenen verändert werden. Ein Preset stellt einen vollständigen Stil
wieder her. Stil-Dateien lassen sich speichern, weitergeben und wieder
importieren. Sonnenrichtung, Reliefstärke und Überhöhung wirken sofort.

Straßen, Eisenbahnen, Flüsse, Grenzen und Ortsnamen erscheinen abhängig von
der Zoomstufe. Nicht benötigte Ebenen können ausgeschaltet werden.

## Suche und Informationen

Die Suche akzeptiert Ortsnamen sowie Koordinaten. Ein Treffer wird direkt
zentriert. Unter dem Mauszeiger zeigt die App – sofern in den Daten vorhanden –
Koordinaten, Höhe und Landklasse. Häufig benötigte Ausschnitte können als
Lesezeichen gespeichert werden.

## Zeitvergleich

Die Landbedeckungsjahre 2015 und 2020 verwenden denselben Kartenstil. Mit dem
Jahresumschalter wird die aktive Ebene gewählt; die Vergleichsansicht stellt
beide Zeitstände im gleichen Ausschnitt gegenüber. Ein Stilwechsel gilt für
beide Seiten.

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
