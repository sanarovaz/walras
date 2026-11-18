#!/bin/zsh
# Compila Walras e instala la app en ~/Applications. Sólo usa el compilador
# de Swift de las herramientas de línea de comandos de Apple; no descarga nada.
cd "${0:A:h}" || exit 1
exec > >(tee build.log) 2>&1

APP="$HOME/Applications/Walras.app"
OLD_APP="$HOME/Applications/Bunker.app"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "FALTA: las herramientas de línea de comandos de Apple."
    echo "Instalalas con: xcode-select --install y volvé a abrir este archivo."
    xcode-select --install
    exit 1
fi

xcrun swiftc --version
echo "Compilando…"
if ! xcrun swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos13" \
    -framework AppKit -framework PDFKit -framework Quartz -framework UniformTypeIdentifiers \
    Sources/*.swift -o "$BUILD/Walras"; then
    echo "BUILD FAILED"
    exit 1
fi

# Cierra la versión abierta; sus archivos ya se guardan solos al salir.
osascript -e 'tell application id "io.github.sanarovaz.texlocal" to quit' >/dev/null 2>&1
sleep 1

STAGE="$BUILD/Walras.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/Walras" "$STAGE/Contents/MacOS/Walras"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp Resources/WindowLogo.png "$STAGE/Contents/Resources/WindowLogo.png"
codesign --force --deep --sign - "$STAGE" || { echo "BUILD FAILED"; exit 1; }

mkdir -p "$HOME/Applications"
rm -rf "$APP" "$OLD_APP"
rm -f "Compilar Bunker.command"
cp -R "$STAGE" "$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$OLD_APP" >/dev/null 2>&1
"$LSREGISTER" -f "$APP"

echo "BUILD OK: $APP"
open "$APP"
