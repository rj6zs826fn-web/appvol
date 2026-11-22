#!/bin/sh
# Baut das CLI (appvol) und die Notch-App (AppVol.app).
set -e
cd "$(dirname "$0")"

# CLI: Info.plist wird eingebettet, damit macOS nach der Audioaufnahme-Freigabe fragen kann
swiftc -O Core.swift main.swift -o appvol \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./appvol selftest

# App
rm -rf AppVol.app
mkdir -p AppVol.app/Contents/MacOS
cp App/Info.plist AppVol.app/Contents/Info.plist
swiftc -O -parse-as-library Core.swift App/NotchApp.swift -o AppVol.app/Contents/MacOS/AppVol
codesign --force --sign - AppVol.app  # ad-hoc, damit die Audio-Freigabe gemerkt wird
echo "gebaut: ./appvol und ./AppVol.app"
