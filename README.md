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
- **Claude:** Status aller Claude-Code-Sitzungen (arbeitet / Rückfrage / fertig). Neben der Notch zeigen ein Symbol und eine Zahl, wie viele Sitzungen aktiv sind. Wird eine Sitzung fertig oder braucht sie dich, klappt die Notch für 6 Sekunden von selbst auf. Ein Klick springt direkt in den passenden Chat der Claude-App (`claude://code/continue?session=…`). Voraussetzung sind die Hooks unten.
- **Ablage:** Dateien auf die Notch ziehen, später wieder herausziehen. Rechtsklick zeigt die Datei im Finder oder entfernt sie aus der Ablage. Die Ablage merkt sich die Dateien nur, solange die App läuft.
- **Transkript** (standardmäßig aus): Video oder Audio auf die Notch ziehen, während der Tab Transkript offen ist. Das Transkript entsteht lokal, landet als `.txt` in der Ablage und auf Wunsch in der Zwischenablage. Einrichtung siehe unten.
- **Schalter:** alle Lautstärken zurücksetzen, App beenden. Gibt es `~/mcp/safari`, kommt zusätzlich ein Zeitschalter für einen lokalen Safari-MCP-Server dazu.

Vorschau ohne Maus, zum Beispiel für Screenshots:
```sh
APPVOL_PREVIEW=volume ./AppVol.app/Contents/MacOS/AppVol   # volume | claude | shelf | transcribe | safari
```

## Claude-Status einrichten
`claude-status-hook.py` schreibt pro Sitzung eine Statusdatei nach `~/Library/Application Support/AppVol/claude/`. Trag ihn in `~/.claude/settings.json` für `UserPromptSubmit`, `PostToolUse` (matcher `*`), `Notification`, `Stop` und `SessionEnd` ein:
```json
{ "type": "command", "command": "python3 -I \"$HOME/Developer/appvol/claude-status-hook.py\"", "timeout": 5, "async": true }
```
Titel und Direktlink liest AppVol aus den Sitzungsdateien der Claude-Desktop-App. Das ist ein internes Format: Ändert es sich, fehlen nur Titel und Direktlink, der Status funktioniert weiter.

## Transkript einrichten
1. Werkzeuge installieren: `brew install ffmpeg whisper-cpp`
2. Einstellungen → Funktionen → **Transkript** einschalten. Dort steht, ob `ffmpeg` und `whisper-cli` gefunden wurden (gesucht wird in `/opt/homebrew/bin`, `/usr/local/bin` und im PATH).
3. Modell wählen und **Laden** drücken: base (≈ 150 MB, schnell), small (≈ 490 MB) oder large-v3-turbo (≈ 570 MB, beste Qualität). Der Download kommt direkt von Hugging Face (`ggerganov/whisper.cpp`) nach `~/Library/Application Support/AppVol/models/` und wird per SHA-256 geprüft. Hast du schon eine `ggml-*.bin`, wähle sie mit **Datei wählen …**.
4. Sprache wählen (Automatisch erkennt sie selbst).

Ablauf: `ffmpeg` macht aus der Datei ein 16-kHz-Mono-WAV, `whisper-cli` schreibt den Text. Fortschritt und **Abbrechen** stehen im Tab, wenn es fertig ist, klappt die Notch kurz auf. Das Transkript liegt in `~/Library/Application Support/AppVol/Shelf/` und wird mit der Ablage gelöscht. Andere Dateien landen wie gewohnt in der Ablage.

Test ohne Oberfläche (nutzt das Modell aus den Einstellungen):
```sh
APPVOL_TRANSCRIBE=datei.mp4 ./AppVol.app/Contents/MacOS/AppVol                               # druckt Text und Dauer
APPVOL_TRANSCRIBE=datei.mp4 APPVOL_TRANSCRIBE_CANCEL=2 ./AppVol.app/Contents/MacOS/AppVol    # Abbruch nach 2 s
```

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
- Wechselst du das Ausgabegerät, zum Beispiel weil du AirPods verbindest, musst du appvol neu starten.
- Wird appvol hart beendet (`kill -9`), bleibt die App stumm, bis der Prozess endet. Ein normales `Ctrl+C` räumt sauber auf.

## Lizenz
MIT
