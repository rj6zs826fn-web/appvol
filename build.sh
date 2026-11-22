#!/bin/sh
# Baut das CLI (appvol) und die Notch-App (AppVol.app).
set -e
cd "$(dirname "$0")"

# CLI: Info.plist wird eingebettet, damit macOS nach der Audioaufnahme-Freigabe fragen kann
swiftc -O Core.swift main.swift -o appvol \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./appvol selftest

# Selbsttests der Claude-Einrichtung (Merge von settings.json) und des Hooks
swiftc -parse-as-library App/ClaudeSetup.swift tests/ClaudeSetupTest.swift -o .claude-setup-test
./.claude-setup-test; rm -f .claude-setup-test
python3 -I tests/test_hook.py claude-status-hook.py

# App
rm -rf AppVol.app
mkdir -p AppVol.app/Contents/MacOS AppVol.app/Contents/Resources
cp App/Info.plist AppVol.app/Contents/Info.plist
cp claude-status-hook.py AppVol.app/Contents/Resources/  # „Claude-Status einrichten“ kopiert es von hier
swiftc -O -parse-as-library Core.swift App/*.swift -o AppVol.app/Contents/MacOS/AppVol
codesign --force --sign - AppVol.app  # ad-hoc, damit die Audio-Freigabe gemerkt wird
echo "gebaut: ./appvol und ./AppVol.app"
