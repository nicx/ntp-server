#!/usr/bin/env bash
set -euo pipefail

# Baut NTPServer.app rein mit Apple-Bordmitteln (Swift Toolchain aus den
# Command Line Tools). Kein Homebrew, kein Xcode-GUI nötig.

APP_NAME="NTPServer"
BUILD_DIR=".build/release"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

# Signier-Identität. Default "-" = ad-hoc: baut ohne Zertifikat, vergibt aber keine
# Code-Identität — der CDHash wechselt bei jedem Rebuild, macOS erkennt die App nicht
# wieder und verwirft erteilte Berechtigungen (Mitteilungen, Gatekeeper). Mit stabiler
# selbstsignierter Identität bleiben sie erhalten:
#     CODESIGN_IDENTITY="nicx Selfsign" ./build_app.sh
# Verfügbare Identitäten: security find-identity -v -p codesigning
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Baue Release-Binary…"
swift build -c release

echo "==> Erzeuge ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>NTP Server</string>
    <key>CFBundleIdentifier</key><string>app.ntpserver</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "==> Signatur: ad-hoc (Hinweis: CODESIGN_IDENTITY setzen für stabile Identität)"
else
  echo "==> Signatur: ${CODESIGN_IDENTITY}"
fi
codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo ""
echo "==> Fertig: $(pwd)/${APP_BUNDLE}"
echo "    Start: open ${APP_BUNDLE}"
echo "    Erststart ggf. via Rechtsklick > Öffnen (Gatekeeper)."
