#!/bin/sh
# Baut appvol; Info.plist wird eingebettet, damit macOS nach der Audioaufnahme-Freigabe fragen kann.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o appvol \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
./appvol selftest
