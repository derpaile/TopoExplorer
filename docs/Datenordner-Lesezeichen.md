# Dauerhafter Zugriff auf den Datenordner

## Ziel

TopoExplorer speichert keinen festen Rechnerpfad, sondern ein
`security-scoped bookmark` des vom Benutzer gewählten Ordners. So bleibt der
Zugriff nach App-Neustart, Verschieben der App und späterer Aktivierung der
macOS-App-Sandbox erhalten.

## Ablauf

1. Die Ordnerauswahl liefert eine URL für `MapData/Germany` oder `MapData`.
2. Nach Prüfung von `manifest.json` erzeugt die App mit
   `.withSecurityScope` ein Bookmark und speichert dessen `Data` in den
   Programmeinstellungen.
3. Beim Start wird die URL mit
   `URL(resolvingBookmarkData:options:.withSecurityScope, …)` rekonstruiert.
4. Vor dem ersten Dateizugriff ruft die App
   `startAccessingSecurityScopedResource()` auf. Beim Wechsel des Ordners wird
   der bisherige Zugriff mit `stopAccessingSecurityScopedResource()` beendet.
5. Meldet macOS ein veraltetes Bookmark, wird es aus der aufgelösten URL neu
   erzeugt. Schlägt die Auflösung fehl, zeigt die App wieder die Ordnerwahl an.

## Datenmodell und Migration

- Schlüssel: `TopoExplorer.dataDirectoryBookmark.v1`
- Wert: rohe Bookmark-Daten in `UserDefaults`; sie enthalten keine
  Kartendaten.
- Der bisherige Pfadschlüssel `TopoExplorer.dataDirectory.v1` bleibt als
  Rückfall für Entwicklungs-Builds erhalten. Unter der Sandbox fordert die App
  erneut eine Ordnerauswahl an, falls daraus kein gültiges Bookmark entsteht.
- Zuletzt gewählter Ordner und aktiver Zugriff werden getrennt gehalten. Damit
  bleiben Wechsel und Fehlerfälle ausgeglichen.

## Signierung und Sandbox

Das Xcode-Ziel und das Release-Skript signieren die App mit aktivierter
Sandbox und genau diesen Dateirechten:

```text
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-write = true
com.apple.security.files.bookmarks.app-scope = true
```

Schreibzugriff gilt nur für ausdrücklich gewählte Exportziele. Der persistierte
Kartendaten-Bookmark wird weiterhin mit `securityScopeAllowOnlyReadAccess`
erzeugt. Die Laufzeit erneuert veraltete Bookmarks und fordert bei ungültigem
Zugriff erneut die Ordnerwahl an. Vor einer Freigabe werden Auswahl, Neustart,
verschobener Datenordner, veraltetes Bookmark und entzogene Berechtigung
manuell geprüft.
