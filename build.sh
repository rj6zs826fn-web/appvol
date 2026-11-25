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
# Icon: App/AppIcon.png (1024+) -> AppIcon.icns
I=$(mktemp -d)/AppIcon.iconset; mkdir -p "$I"
for n in 16 32 128 256 512; do
  sips -z $n $n App/AppIcon.png --out "$I/icon_${n}x${n}.png" >/dev/null
  sips -z $((n*2)) $((n*2)) App/AppIcon.png --out "$I/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$I" -o AppVol.app/Contents/Resources/AppIcon.icns
cp claude-status-hook.py AppVol.app/Contents/Resources/  # „Claude-Status einrichten“ kopiert es von hier
swiftc -O -parse-as-library Core.swift App/*.swift -o AppVol.app/Contents/MacOS/AppVol

# MediaRemoteAdapter (BSD-3, vendor/) aus dem Quellcode: liefert „Was läuft gerade“ für die Musiksteuerung
M=vendor/mediaremote-adapter
F=AppVol.app/Contents/Frameworks/MediaRemoteAdapter.framework
mkdir -p "$F/Versions/A/Resources" AppVol.app/Contents/Resources
clang -O2 -fobjc-arc -fvisibility=default -dynamiclib -arch arm64 -arch x86_64 -I$M/include -I$M/src \
  $M/src/adapter/*.m $M/src/private/*.m $M/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$F/Versions/A/MediaRemoteAdapter"
P="$F/Versions/A/Resources/Info.plist"
plutil -create xml1 "$P"
plutil -insert CFBundleIdentifier -string io.github.appvol.MediaRemoteAdapter "$P"
plutil -insert CFBundleExecutable -string MediaRemoteAdapter "$P"
plutil -insert CFBundlePackageType -string FMWK "$P"
ln -s A "$F/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$F/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$F/Resources"
cp $M/bin/mediaremote-adapter.pl AppVol.app/Contents/Resources/
cp $M/LICENSE AppVol.app/Contents/Resources/MediaRemoteAdapter-LICENSE
codesign --force --sign - "$F"
codesign --force --sign - AppVol.app  # ad-hoc, damit die Audio-Freigabe gemerkt wird
echo "gebaut: ./appvol und ./AppVol.app"
