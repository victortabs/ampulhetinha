#!/bin/bash
# Compila a Ampulhetinha e monta build/Ampulhetinha.app
#   ./Scripts/build.sh            → só compila
#   ./Scripts/build.sh install    → compila, instala em /Applications e abre
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Ampulhetinha.app"

echo "▸ Compilando…"
swift build -c release

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Gerando ícone…"
  swift Scripts/make-icon.swift Resources >/dev/null
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf Resources/AppIcon.iconset
fi

echo "▸ Montando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Ampulhetinha" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - --identifier com.victortaborda.ampulhetinha "$APP"

if [ "${1:-}" = "install" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x Ampulhetinha 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST/Ampulhetinha.app"
  cp -R "$APP" "$DEST/"
  echo "▸ Instalado em $DEST/Ampulhetinha.app"
  open "$DEST/Ampulhetinha.app"
else
  echo "✓ Pronto: $APP"
fi
