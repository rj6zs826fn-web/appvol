# appvol

Lautstärke einzelner Apps auf macOS regeln, z. B. einen Anruf leiser stellen, ohne den Rest leiser zu machen.
Ein kleines Kommandozeilen-Tool (eine Swift-Datei), ohne Treiber und ohne Kernel-Erweiterung.

*Per-app volume control for macOS from the command line, built on Core Audio process taps.*

## Voraussetzungen
- macOS 14.4 oder neuer
- Xcode oder die Command Line Tools (`swiftc`)

## Bauen
```sh
./build.sh
```
Das baut das Kommandozeilen-Tool `appvol` und die Notch-App `AppVol.app`.

## Notch-App
```sh
open AppVol.app
```
Fährst du mit der Maus an die Notch, klappt ein Panel auf. Ohne Notch erscheint oben in der Mitte eine schwarze Pseudo-Notch. Dasselbe Panel gibt es auch über das Symbol in der Menüleiste.
- **Lautstärke:** oben die Gesamtlautstärke, darunter ein Regler für jede App, die gerade Ton abspielt (0–300 %). Über 100 % wird die App lauter als normal, die Zahl wird dann orange. Bei 100 % rastet der Regler ein und der Tap wird wieder entfernt.
- **Ausgabegerät:** oben im Lautstärke-Tab eine Auswahl aller Ausgabegeräte (Lautsprecher, Kopfhörer, AirPods, Monitor …). Wechselt das Gerät, ob per Auswahl oder weil du AirPods verbindest, legt AppVol die geänderten App-Lautstärken auf dem neuen Gerät neu an.
- **Musik:** Titel, Interpret und Cover dessen, was gerade läuft (Musik, Spotify, Browser, Podcasts …), mit Play/Pause, Vor und Zurück. Keine Einrichtung nötig, Details unten.
- **Claude:** Status aller Claude-Code-Sitzungen (arbeitet / Rückfrage / fertig). Neben der Notch zeigen ein Symbol und eine Zahl, wie viele Sitzungen aktiv sind. Wird eine Sitzung fertig oder braucht sie dich, klappt die Notch für 6 Sekunden von selbst auf. Ein Klick springt direkt in den passenden Chat der Claude-App (`claude://code/continue?session=…`). Voraussetzung sind die Hooks unten.
- **Ablage:** Dateien auf die Notch ziehen, später wieder herausziehen. Rechtsklick zeigt die Datei im Finder oder entfernt sie aus der Ablage. Die Ablage merkt sich die Dateien nur, solange die App läuft.
- **Schalter:** alle Lautstärken zurücksetzen, App beenden. Gibt es `~/mcp/safari`, kommt zusätzlich ein Zeitschalter für einen lokalen Safari-MCP-Server dazu.

Vorschau ohne Maus, zum Beispiel für Screenshots:
```sh
APPVOL_PREVIEW=volume ./AppVol.app/Contents/MacOS/AppVol   # volume | media | claude | shelf | safari
```

## Claude-Status einrichten
`claude-status-hook.py` schreibt pro Sitzung eine Statusdatei nach `~/Library/Application Support/AppVol/claude/`. Trag ihn in `~/.claude/settings.json` für `UserPromptSubmit`, `PostToolUse` (matcher `*`), `Notification`, `Stop` und `SessionEnd` ein:
```json
{ "type": "command", "command": "python3 -I \"$HOME/Developer/appvol/claude-status-hook.py\"", "timeout": 5, "async": true }
```
Titel und Direktlink liest AppVol aus den Sitzungsdateien der Claude-Desktop-App. Das ist ein internes Format: Ändert es sich, fehlen nur Titel und Direktlink, der Status funktioniert weiter.

## Musiksteuerung
Seit macOS 15.4 lässt Apple fremde Apps nicht mehr an das private MediaRemote-Framework, das weiß, was gerade läuft. AppVol nutzt dafür den quelloffenen [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) von Jonas van den Berg (BSD-3-Clause, mit MIT verträglich):
- Ein kleines Framework wird in das von Apple berechtigte `/usr/bin/perl` geladen und meldet Änderungen als JSON-Zeilen; Befehle (Play/Pause, Vor, Zurück) gehen denselben Weg.
- Der Quellcode liegt unverändert in `vendor/mediaremote-adapter/` (Commit `6571499`, 20.11.2026, getestet mit macOS 27.2). `build.sh` baut daraus mit `clang` das Framework und legt es mit dem Perl-Skript und der Lizenz ins App-Bundle. Es wird keine fertige Binärdatei aus dem Netz geladen.
- Keine Freigabe nötig, deshalb ist die Funktion standardmäßig an.

Grenze: Das ist ein Umweg um eine Sperre von Apple. Schließt ein macOS-Update ihn, zeigt der Musik-Tab einen Hinweis statt der Wiedergabe. Dann hilft meist eine neuere Version des Adapters (Ordner in `vendor/` ersetzen, neu bauen) oder die Funktion in den Einstellungen abschalten.

## Nutzung
```sh
./appvol list            # Audio-Prozesse, ▶ = spielt gerade Ton ab
./appvol zoom 40         # Zoom auf 40 %
./appvol zoom 150        # Zoom lauter: 150 % (bis 300 %)
./appvol system 30       # Gesamtlautstärke auf 30 %
./appvol avconferenced 30   # FaceTime- und iPhone-Anrufe auf 30 %
./appvol 12345 50        # per PID
```
- Während es läuft: Zahl eintippen und Enter drücken ändert die Lautstärke live.
- `Ctrl+C` beendet, danach ist der Originalton wieder normal.
- Der Name ist ein Teilstring der Bundle-ID. Passen mehrere Prozesse, werden alle geregelt.
- Ton aus Safari kommt von `com.apple.WebKit.GPU`, aus Chrome von `com.google.Chrome.helper`.

Beim ersten Start fragt macOS nach der Freigabe für **Audioaufnahme**.

## Funktionsweise
1. Ein privater **Process Tap** (`CATapDescription`, `mutedWhenTapped`) greift den Ton der Ziel-App ab und schaltet das Original stumm.
2. Ein privates **Aggregate-Device** aus Standard-Ausgang und Tap spielt den Ton mit der gewählten Lautstärke wieder ab.

## Grenzen
- Lauter als 100 %: Ein Limiter verhindert Übersteuern. Ist die Quelle schon voll ausgesteuert, wird sie dichter statt viel lauter.
- Kommandozeile: Wechselst du das Ausgabegerät, zum Beispiel weil du AirPods verbindest, musst du appvol neu starten. Die Notch-App zieht von selbst nach.
- Wird appvol hart beendet (`kill -9`), bleibt die App stumm, bis der Prozess endet. Ein normales `Ctrl+C` räumt sauber auf.

## Lizenz
MIT. Ausnahme: `vendor/mediaremote-adapter/` steht unter der BSD-3-Clause-Lizenz (siehe `vendor/mediaremote-adapter/LICENSE`, liegt auch im App-Bundle).
