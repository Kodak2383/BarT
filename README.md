# Bar Tool

Ein Bartender-Klon für macOS — Menüleisten-Verwaltungsapp. Items lassen sich verstecken, per Klick aufs eigene Icon vorübergehend wieder einblenden, und die Zuordnung überlebt den Neustart.

Getestet auf macOS 26. Die Engine beruht auf privaten CGS-Aufrufen und simulierten Cmd-Drags (siehe `DragHideEngine`), ist also an das Verhalten dieser OS-Version gebunden.

## Voraussetzungen

**Wichtig:** Du benötigst die vollständige Xcode IDE, nicht nur die Command Line Tools.

Prüfen Sie, ob Xcode installiert ist:
```bash
xcode-select -p
```

Sollte `/Applications/Xcode.app/Contents/Developer` anzeigen. Wenn nicht (z.B. nur Command Line Tools installiert), installieren Sie Xcode über den App Store und führen aus:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Zusätzlich benötigt:
- **xcodegen** (um `project.yml` in Xcode-Projekt zu konvertieren): `brew install xcodegen`

## Bauen

```bash
cd "Bar Tool"
xcodegen generate
open "Bar Tool.xcodeproj"
```

Im Xcode-Editor: `Product` → `Build` oder `Cmd+B`.

## Sicherheit & Sandboxing

`BarTool.entitlements` deaktiviert die App Sandbox (`com.apple.security.app-sandbox = false`). Das ist notwendig, weil Bar Tool fremde Anwendungsprozesse über die Accessibility API steuern muss — eine Fähigkeit, die die macOS App Sandbox nicht erlaubt.

## Bedienung

- **Linksklick** aufs Bar-Tool-Icon blendet die versteckten Items vorübergehend ein, erneuter Klick wieder aus. Items in „Immer versteckt" bleiben dabei weg — genau dafür ist die Sektion da.
- **⌥-Klick** blendet zusätzlich „Immer versteckt" ein.
- **⌃⌥⌘B** tut systemweit dasselbe wie der Linksklick.
- Ein Klick irgendwo außerhalb der Menüleiste klappt wieder zu. Klicks *in* der Menüleiste nicht — sonst würde das gerade angeklickte Item unter dem Cursor weggezogen.
- **Rechtsklick** öffnet das Menü (Einstellungen, Debug-Werkzeuge, Beenden).
- In den Einstellungen unter **Items** bekommt jedes Menüleisten-Item eine der drei Sektionen zugewiesen. Die Zuordnung landet in `UserDefaults` und wird beim Start wiederhergestellt.

Die Leiste ist dafür intern in drei Bereiche geteilt, getrennt durch zwei eigene (im Normalfall unsichtbare) Status-Items:

```
[ Sichtbar ] [hidden-Trenner] [ Versteckt ] [alwaysHidden-Trenner] [ Immer versteckt ]
```

Für das Verschieben fremder Items ist die **Bedienungshilfen**-Berechtigung nötig; ohne sie ist auch die Besitzer-Zuordnung falsch (alle Items landen beim Kontrollzentrum). Erteilen lässt sie sich in den Einstellungen unter „Allgemein".

## Aktueller Status

Funktioniert:

- Enumeration aller Menüleisten-Items samt echter Besitzer-App (CGS-Fensterliste + `kAXExtrasMenuBarAttribute`)
- Alle drei Sektionen, per simuliertem Cmd-Drag neben den passenden Trenner
- Persistentes Layout, „Bei Anmeldung starten", Einblenden per Klick, ⌥-Klick und globalem Hotkey, Zuklappen per Klick daneben
- Pendel-Bremse: zwei physisch benachbarte Items lassen sich nicht unabhängig positionieren — ein Drag garantiert nur die Lage des gezogenen Items, der Nachbar rutscht mit. Statt endlos nachzukorrigieren, gibt die App nach drei Versuchen auf und meldet es in den Einstellungen

Noch offen:

- Der Hotkey ist fest verdrahtet (⌃⌥⌘B); bei einer Kollision meldet das die Einstellungen, ändern lässt er sich nicht
- Kein Zuklappen nach Zeit, nur per Klick daneben
- Von macOS fixierte Items (Uhr, Kontrollzentrum) lassen sich nicht bewegen

Hinter dem Debug-Menüpunkt „Layout-Selbsttest" liegen die Selbsttests von `MenuBarLayout` und `OscillationGuard` sowie zwei Prüfungen, die nur am laufenden System möglich sind: die Trenner-Reihenfolge (macOS muss ein neues Status-Item links von den bestehenden platzieren — darauf beruht die gesamte Sektionszuordnung) und die Hotkey-Registrierung. Beides geht auch ohne Menü:

```bash
BARTOOL_SELF_TEST=1 "$(ls -d ~/Library/Developer/Xcode/DerivedData/Bar_Tool-*/Build/Products/Debug/BarTool.app)/Contents/MacOS/BarTool"
```

## Dank

Die Drag-Technik (`scromble`, die windowID-Felder im `CGEvent`) stammt aus [Ice](https://github.com/jordanbaird/Ice) (MIT).
