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
- **Claude:** Status aller Claude-Code-Sitzungen (arbeitet / Rückfrage / fertig). Neben der Notch zeigen ein Symbol und eine Zahl, wie viele Sitzungen aktiv sind. Wird eine Sitzung fertig oder braucht sie dich, klappt die Notch für 6 Sekunden von selbst auf. Ein Klick springt direkt in den passenden Chat der Claude-App (`claude://code/continue?session=…`). Voraussetzung sind die Hooks unten. Optional: Freigaben direkt in der Notch und Anzeige der Claude-Limits.
- **Ablage:** Dateien auf die Notch ziehen, später wieder herausziehen. Rechtsklick zeigt die Datei im Finder oder entfernt sie aus der Ablage. Die Ablage wird standardmäßig beim Systemneustart geleert, alternativ nach einem einstellbaren Intervall (Einstellungen). Gelöscht werden nur Einträge und von AppVol selbst erzeugte Dateien, nie deine Originale.
- **Home Assistant:** gewählte Geräte und Sensoren deines Home Assistant als Kacheln, optional bis zu 2 Sensorwerte neben der Notch. Standardmäßig aus, Einrichtung unten.
- **Transkript** (standardmäßig aus): Video oder Audio auf die Notch ziehen, während der Tab Transkript offen ist. Das Transkript entsteht lokal, landet als `.txt` in der Ablage und auf Wunsch in der Zwischenablage. Einrichtung siehe unten.
- **Safari-MCP** (standardmäßig aus): Zeitschalter für den [Safari-MCP](https://github.com/rj6zs826fn-web/safari-mcp). In den Einstellungen den Ordner des Servers wählen. „30 Min“/„60 Min“ schreiben `.enabled_until` (Unix-Zeit, nur für dich lesbar), „Aus“ setzt sie auf 0 und ruft `python3 server.py off` auf, das auch Claudes eigenes Safari-Fenster schließt. Ohne `server.py` im Ordner bleibt das Fenster offen, der Zugriff ist trotzdem aus.
- **Einstellungen:** Zahnrad im Panel oder Menüleisten-Symbol. Jede Funktion lässt sich einzeln ein- und ausschalten.

Vorschau ohne Maus, zum Beispiel für Screenshots:
```sh
APPVOL_PREVIEW=volume ./AppVol.app/Contents/MacOS/AppVol   # volume | media | claude | shelf | transcribe | safari | homeassistant
```

## Claude-Status einrichten
Einstellungen → Funktionen → **Claude** einschalten → **„Claude-Status einrichten“**. Der Knopf
1. kopiert `claude-status-hook.py` aus der App nach `~/Library/Application Support/AppVol/`,
2. legt eine Sicherungskopie von `~/.claude/settings.json` an (`settings.json.appvol-<Datum>.bak`),
3. trägt den Hook für `UserPromptSubmit`, `PostToolUse` (matcher `*`), `Notification`, `Stop` und `SessionEnd` ein (`async: true`, `timeout: 5`), dazu `PermissionRequest` für die Freigaben (siehe unten),
4. schreibt die Datei atomar. Deine anderen Einstellungen und fremden Hooks bleiben erhalten, nichts wird doppelt eingetragen.

**„Entfernen“** löscht nur die Einträge, die `claude-status-hook.py` aufrufen. Ältere, von Hand eingetragene Einträge mit diesem Skript (anderer Pfad) werden beim Einrichten ersetzt. Die Änderungen gelten für neu gestartete Claude-Sitzungen.

Von Hand geht es auch, ein Eintrag sieht so aus:
```json
{ "type": "command", "command": "python3 -I \"$HOME/Library/Application Support/AppVol/claude-status-hook.py\"", "timeout": 5, "async": true }
```
Titel und Direktlink liest AppVol aus den Sitzungsdateien der Claude-Desktop-App. Das ist ein internes Format: Ändert es sich, fehlen nur Titel und Direktlink, der Status funktioniert weiter.

## Home Assistant einrichten
1. **Token erstellen:** In Home Assistant unten links auf deinen Namen (Profil) klicken, Reiter **Sicherheit**, ganz unten **Langlebige Zugangstoken** → **Token erstellen**. Einen Namen vergeben (z. B. „AppVol“) und den Token kopieren. Er wird nur einmal angezeigt.
2. **Einschalten:** AppVol → Einstellungen → Funktionen → **Home Assistant** einschalten.
3. **Adresse eintragen,** so wie du Home Assistant im Browser öffnest, z. B. `http://homeassistant.local:8123` oder `https://ha.example.org`.
4. **Token einfügen** und **Verbindung testen** drücken. Der Token landet im macOS-Schlüsselbund (Eintrag „AppVol Home Assistant“), nicht in Einstellungsdateien. Fragt macOS nach dem Schlüsselbund-Zugriff, „Immer erlauben“ wählen. Nach jedem Neubauen (`./build.sh`) kann diese Frage einmal wiederkommen, weil die App nur ad hoc signiert ist.
5. **Entitäten wählen:** Nach erfolgreicher Verbindung erscheint die Liste aller Entitäten mit Suchfeld. Haken bei **Panel** zeigt die Entität als Kachel. Haken bei **Notch** zeigt einen Sensorwert neben der Notch (höchstens 2, z. B. PV-Leistung). Ohne Notch-Haken bleibt die Notch unverändert. Laufen Claude-Sitzungen, hat deren Anzeige Vorrang.

Unterstützte Typen:
| Typ | Anzeige im Panel |
|---|---|
| `sensor`, `binary_sensor` und alles andere | Wert mit Einheit |
| `switch`, `light`, `input_boolean`, `fan` | Schalter (umschalten) |
| `cover` | Öffnen / Stopp / Schließen |
| `scene`, `script` | Knopf „Ausführen“ |

AppVol fragt die Werte alle 7 Sekunden per REST-API ab (`GET /api/states`), nur solange die Funktion eingeschaltet ist, und spricht ausschließlich die eingetragene Adresse an (Weiterleitungen werden nicht befolgt). Fehler wie „nicht erreichbar“ oder „Token ungültig“ stehen im Panel und in den Einstellungen. `http` ist nur im Heimnetz möglich (`.local`-Namen und IP-Adressen); von unterwegs `https` verwenden. Beim ersten Zugriff fragt macOS eventuell nach der Freigabe für das **lokale Netzwerk**.

**Abschalten:** Einstellungen → Funktionen → Home Assistant ausschalten. Dann gibt es keine Abfragen mehr. Um den Token ganz zu entfernen, vorher in den Einstellungen **Entfernen** drücken oder in Home Assistant unter Profil → Sicherheit den Token löschen.
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
## Musiksteuerung
Seit macOS 15.4 lässt Apple fremde Apps nicht mehr an das private MediaRemote-Framework, das weiß, was gerade läuft. AppVol nutzt dafür den quelloffenen [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) von Jonas van den Berg (BSD-3-Clause, mit MIT verträglich):
- Ein kleines Framework wird in das von Apple berechtigte `/usr/bin/perl` geladen und meldet Änderungen als JSON-Zeilen; Befehle (Play/Pause, Vor, Zurück) gehen denselben Weg.
- Der Quellcode liegt unverändert in `vendor/mediaremote-adapter/` (Commit `6571499`, 20.11.2026, getestet mit macOS 27.2). `build.sh` baut daraus mit `clang` das Framework und legt es mit dem Perl-Skript und der Lizenz ins App-Bundle. Es wird keine fertige Binärdatei aus dem Netz geladen.
- Keine Freigabe nötig, deshalb ist die Funktion standardmäßig an.

Grenze: Das ist ein Umweg um eine Sperre von Apple. Schließt ein macOS-Update ihn, zeigt der Musik-Tab einen Hinweis statt der Wiedergabe. Dann hilft meist eine neuere Version des Adapters (Ordner in `vendor/` ersetzen, neu bauen) oder die Funktion in den Einstellungen abschalten.
### Freigaben in der Notch (Schalter, standardmäßig aus)
Fragt Claude, ob es ein Werkzeug benutzen darf (z. B. einen Befehl ausführen), klappt die Notch mit **Erlauben** / **Ablehnen** auf.
- Grundlage ist der offizielle `PermissionRequest`-Hook von Claude Code. Laut Doku läuft er überall, wo Claude Code läuft, auch in der Desktop-App. Dort gilt die Antwort, die zuerst kommt: Notch oder Claudes eigener Dialog.
- Ablauf: Der Hook legt die Anfrage (Werkzeug, Kurzbeschreibung, Ordner) mit einer zufälligen ID in `~/Library/Application Support/AppVol/claude/permissions/` ab und wartet höchstens 60 s auf die Antwortdatei der App. Kommt keine, gibt er nichts zurück, und Claude fragt wie gewohnt. Im Terminal erscheint der Dialog dann erst nach dieser Wartezeit.
- Der Hook wartet nur, solange AppVol läuft und der Schalter an ist (AppVol erneuert dafür alle paar Sekunden `permissions/.alive`). Sonst kehrt er sofort zurück.
- Sicherheit: Es wird nie automatisch erlaubt, nur auf deinen Klick, und nur einmal. Dauerhafte Regeln (`updatedPermissions`) werden nie gesetzt. Der Ordner hat die Rechte 700, Antwortdateien 600. Der Hook nimmt eine Antwort nur an, wenn sie dir gehört, für niemanden sonst lesbar ist, keine Verknüpfung ist und die passende Anfrage-ID enthält.

### Nutzung anzeigen (Schalter, standardmäßig aus)
Zeigt im Claude-Tab z. B. „5-h-Limit 42 %  7-Tage-Limit 12 %“ (ab 70 % orange, ab 90 % rot).
- Quelle sind die offiziell dokumentierten Felder `rate_limits.five_hour` und `rate_limits.seven_day`, die Claude Code einem **statusLine**-Befehl übergibt. Es werden keine inoffiziellen Schnittstellen und keine Zugangsdaten aus dem Schlüsselbund benutzt.
- Einrichten per Knopf **„statusLine einrichten“** (unter dem Schalter). Hast du schon eine eigene `statusLine`, bricht AppVol mit einem Hinweis ab und überschreibt sie nicht. Du kannst dann in deinem eigenen Skript die Eingabe zusätzlich an `python3 -I "$HOME/Library/Application Support/AppVol/claude-status-hook.py" statusline` weiterreichen.
- Grenzen: Die Werte gibt es nur für Pro-, Max- und Ultra-Abos und erst nach der ersten Antwort einer Sitzung. Die statusLine läuft in Claude Code im Terminal. Ob die Desktop-App sie ausführt, ist nicht dokumentiert. Die Anzeige verschwindet, wenn das Zeitfenster abgelaufen ist.

### Testen ohne echte Einstellungen
```sh
APPVOL_CLAUDE_SETTINGS=/tmp/test/settings.json   # andere settings.json für die Knöpfe
APPVOL_CLAUDE_DIR=/tmp/test/claude               # andere Status-, Freigabe- und Nutzungsdateien (App und Hook)
```
`./build.sh` führt die Selbsttests aus: `tests/ClaudeSetupTest.swift` (Zusammenführen mit fremden Hooks und anderen Schlüsseln, Entfernen, statusLine, Antwortdatei) und `tests/test_hook.py` (Freigabe erlauben, ablehnen und ignorieren, statusLine).

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
