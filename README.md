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

## Nutzung
```sh
./appvol list            # Audio-Prozesse, ▶ = spielt gerade Ton ab
./appvol zoom 40         # Zoom auf 40 %
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
- Nur leiser (0–100 %), nicht lauter.
- Wechselst du das Ausgabegerät, zum Beispiel weil du AirPods verbindest, musst du appvol neu starten.
- Wird appvol hart beendet (`kill -9`), bleibt die App stumm, bis der Prozess endet. Ein normales `Ctrl+C` räumt sauber auf.

## Lizenz
MIT
