#!/bin/bash
# Builds "CCM Card Ingest.app" so the app opens with a double-click, like any
# other Mac app, instead of typing `swift run` in Terminal.
#
#   scripts/make-app.sh               # build and put the app in /Applications
#   scripts/make-app.sh --no-install  # build only; the app is left in .build/
#
# Run it again after pulling new code to update the app. Settings are kept,
# because they live in ~/Library/Application Support/Card Ingest, not in the app.
#
# Live Tech Support writes to the WhatsApp number in scripts/support-whatsapp.txt
# (one line, with the country code, e.g. +1 555 123 4567), or in the
# CARD_INGEST_SUPPORT_WHATSAPP variable. It's built into the app so photographers
# don't have to set it. The file is kept out of git, as this repository is public.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="CCM Card Ingest"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

echo "Building (this takes a minute the first time)…"
swift build -c release --product CardIngest
BIN="$(swift build -c release --show-bin-path)/CardIngest"

APP=".build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CardIngest"

VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0)"
SUPPORT="${CARD_INGEST_SUPPORT_WHATSAPP:-}"
if [ -z "$SUPPORT" ] && [ -f scripts/support-whatsapp.txt ]; then
    SUPPORT="$(head -n 1 scripts/support-whatsapp.txt)"
fi
# Only what a phone number can hold, so nothing else gets into the plist.
SUPPORT="$(printf '%s' "$SUPPORT" | tr -cd '0-9+ ()-')"
if [ -z "$SUPPORT" ]; then
    echo "Note: no support number (scripts/support-whatsapp.txt), so Live Tech Support can't send until one is set."
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.capturecampmemories.cardingest</string>
    <key>CFBundleExecutable</key><string>CardIngest</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Card Ingest copies photos from camera cards.</string>
    <key>CardIngestSupportWhatsApp</key><string>${SUPPORT}</string>
</dict>
</plist>
PLIST

# A local signature so macOS treats it as a normal app on this Mac.
codesign --force --sign - "$APP" >/dev/null

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/${APP_NAME}.app"
    cp -R "$APP" "$DEST/"
    echo "Done. ${APP_NAME} is in ${DEST}. Double-click it there, or drag it to the Dock."
else
    echo "Done. The app is at ${APP}."
fi
