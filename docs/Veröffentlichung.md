# macOS-Veröffentlichung

## Voraussetzungen

- macOS 14.4 oder neuer
- Xcode 16 für Archiv/Test; die Command Line Tools genügen für einen lokalen
  ad-hoc signierten Build
- fertig erzeugte Kartendaten für den Funktionstest

Das eingecheckte `TopoExplorer.xcodeproj` wird reproduzierbar erzeugt:

```sh
./scripts/generate_app_icon.sh
./scripts/generate_xcode_project.py
```

Der Generator nimmt alle Swift-Dateien aus `Sources/TopoExplorer` und
`Tests/TopoExplorerTests` alphabetisch auf. Nach neuen Dateien wird er erneut
ausgeführt. In Xcode ist das gemeinsame Schema `TopoExplorer` für Build, Test,
Profiling und Archiv vorhanden.

## Lokales DMG

```sh
./scripts/release_macos.sh
```

Das Ergebnis liegt unter `.build/release/`. Ohne vollständiges Xcode verwendet
das Skript den direkten Swift-Build. Es erzeugt das App-Icon neu, setzt
Versionen, signiert ad-hoc, prüft die Signatur und baut ein komprimiertes DMG.

Ein schneller Test ohne DMG:

```sh
TOPO_SKIP_DMG=1 ./scripts/release_macos.sh
```

Ein bereits gebautes Bundle kann mit `TOPO_SOURCE_APP=/Pfad/TopoExplorer.app`
verpackt werden. Das ist für reine Verpackungstests gedacht; die reguläre
Freigabe baut immer aus den Quellen.

## Developer ID und Notarisierung

Die Signierungsidentität wird nicht im Projekt gespeichert:

```sh
TOPO_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
TOPO_VERSION=1.0.0 \
TOPO_BUILD_NUMBER=100 \
./scripts/release_macos.sh
```

Notarisierungsdaten werden einmalig in Apples Schlüsselbund abgelegt:

```sh
xcrun notarytool store-credentials TopoExplorer-Notary \
  --apple-id DEINE-APPLE-ID \
  --team-id TEAMID
```

Danach kann dasselbe Release-Skript senden, warten und das Ticket anheften:

```sh
TOPO_CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
TOPO_NOTARY_PROFILE=TopoExplorer-Notary \
./scripts/release_macos.sh
```

Passwörter und Schlüssel erscheinen weder in Skripten noch im Repository.

## Freigabeprüfung

1. `./scripts/verify_image_quality.sh`
2. In Xcode: Product → Test sowie Product → Archive
3. DMG auf einem zweiten Benutzerkonto öffnen
4. App nach `/Applications` ziehen, Kartendaten wählen und neu starten
5. Suche, Stilimport/-export, Ebenen, Zeitvergleich und PNG-Export prüfen
6. Datenordnerzugriff nach Neustart, Verschieben und Berechtigungsentzug prüfen
7. `codesign --verify --deep --strict TopoExplorer.app`
8. Bei notariertem Release: `spctl --assess --type execute --verbose TopoExplorer.app`
