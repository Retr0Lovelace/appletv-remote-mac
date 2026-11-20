#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Télécommande Apple TV.app"
rm -rf "$APP" build/icon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

# Les macros SwiftUI (@State...) sont fournies par Xcode.app, absentes des seuls Command Line Tools.
PLUGIN=""
for p in /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins; do
  [ -d "$p" ] && PLUGIN="-plugin-path $p"
done

swiftc -O $PLUGIN -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
  -o "$APP/Contents/MacOS/AppleTVRemote" Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"

# Icône (optionnelle)
if swiftc -O -o build/makeicon tools/makeicon.swift 2>/dev/null && build/makeicon build/icon.png 2>/dev/null; then
  mkdir -p build/icon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns" || true
else
  echo "Icône ignorée"
fi

codesign --force --deep -s - "$APP"
echo "OK : $APP"
