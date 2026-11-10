#!/bin/bash
# Builds build/Gradient.app with Xcode Command Line Tools only (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Gradient.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"

echo "▸ compiling"
swiftc -O -o "$APP/Contents/MacOS/Gradient" Sources/main.swift \
  -framework Cocoa -framework WebKit

cp Info.plist "$APP/Contents/Info.plist"
cp web/index.html "$APP/Contents/Resources/web/index.html"

if [ -f icon/AppIcon-1024.png ]; then
  echo "▸ icon"
  SET="build/AppIcon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon/AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d icon/AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$SET"
fi

echo "▸ signing (ad-hoc)"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "✓ $APP"
echo "  open build/Gradient.app   # run"
echo "  cp -R build/Gradient.app /Applications/   # install"
