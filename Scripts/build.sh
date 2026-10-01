#!/bin/bash
# Compila a Ampulhetinha e monta build/Ampulhetinha.app
#   ./Scripts/build.sh            → só compila
#   ./Scripts/build.sh install    → compila, instala em /Applications e abre
#   ./Scripts/build.sh release    → app universal (Apple Silicon + Intel) zipado em build/Ampulhetinha.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Ampulhetinha.app"
ARCHS=()
[ "${1:-}" = "release" ] && ARCHS=(--arch arm64 --arch x86_64)

echo "▸ Compilando…"
# Usa o Xcode se estiver instalado, mesmo que o xcode-select aponte para as Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# As Command Line Tools do macOS 27 não trazem o plugin SwiftUIMacros (@State virou macro):
# se falhar, tenta de novo com o SDK 26 mais novo instalado.
if ! swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}; then
  OLD_SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  [ -n "$OLD_SDK" ] || exit 1
  echo "▸ Tentando de novo com $(basename "$OLD_SDK")…"
  export SDKROOT="$OLD_SDK"
  swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
fi

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Gerando ícone…"
  swift Scripts/make-icon.swift Resources >/dev/null
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
  rm -rf Resources/AppIcon.iconset
fi

echo "▸ Montando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Ampulhetinha" "$APP/Contents/MacOS/"
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
elif [ "${1:-}" = "release" ]; then
  rm -f build/Ampulhetinha.zip
  ditto -c -k --keepParent "$APP" build/Ampulhetinha.zip
  echo "✓ Pronto: build/Ampulhetinha.zip"
  shasum -a 256 build/Ampulhetinha.zip
else
  echo "✓ Pronto: $APP"
fi
