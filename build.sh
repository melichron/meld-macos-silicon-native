#!/bin/sh
set -eu
cd "$(dirname "$0")"
dest="MeldMac.app/Contents"
mkdir -p "$dest/MacOS" "$dest/Resources"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "${TMPDIR:-/tmp}/meldmac-module-cache" CopyFile.swift Model.swift Folders.swift BlockLinks.swift FileEditor.swift Preferences.swift App.swift -o "$dest/MacOS/MeldMac"
cp Resources/*.py Resources/MeldMac.icns LICENSE NOTICE "$dest/Resources/"
cp Info.plist "$dest/"
codesign --force --sign - MeldMac.app
