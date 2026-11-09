#!/bin/bash
# Builds "CC Media Sherpa.app" so the app opens with a double-click, like any
# other Mac app, instead of typing `swift run` in Terminal.
#
#   scripts/make-app.sh               # build and put the app in /Applications
#   scripts/make-app.sh --no-install  # build only; the app is left in .build/
#
# Run it again after pulling new code to update the app. Settings are kept,
# because they live in ~/Library/Application Support/Media Sherpa, not in the app.
#
# Live Tech Support writes to the WhatsApp number in scripts/support-whatsapp.txt
# (one line, with the country code, e.g. +1 555 123 4567), or in the
# MEDIA_SHERPA_SUPPORT_WHATSAPP variable. It's built into the app so photographers
# don't have to set it. The file is kept out of git all the same.
#
# Ship/Settings.plist goes in the app as it is, and is what a new user's settings
# start from. The build stops if it has a typo or a phone alert topic.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="CC Media Sherpa"
# What the app was called before, so installing removes the old copy.
OLD_NAMES=("CCM Card Ingest")
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

echo "Building (this takes a minute the first time)…"
swift build -c release --product MediaSherpa
BIN="$(swift build -c release --show-bin-path)/MediaSherpa"

SHIPPED="Ship/Settings.plist"
if [ -f "$SHIPPED" ] && ! "$BIN" --check-shipped-settings "$SHIPPED"; then
    echo "Nothing was installed. Fix $SHIPPED and build again." >&2
    exit 1
fi

APP=".build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MediaSherpa"
if [ -f "$SHIPPED" ]; then
    cp "$SHIPPED" "$APP/Contents/Resources/Settings.plist"
    echo "New users start from $SHIPPED."
else
    echo "Note: no $SHIPPED, so new users start from the built-in defaults."
fi

# The version people see is in the VERSION file ("1.0 beta"); the build is the
# commit it was made from, so a problem report says exactly which code it was.
VERSION="$(head -n 1 VERSION 2>/dev/null || echo 1.0)"
BUILD="$(git describe --tags --always --dirty 2>/dev/null || echo "$VERSION")"

# The logo, as the app's icon (Dock, Finder and the About box), when
# scripts/logo.png is there: square, ideally 1024 x 1024 with a clear background.
ICON_KEY=""
if [ -f scripts/logo.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # A logo that fills its whole square (no clear background) is rounded into
    # the Mac icon shape, so it doesn't sit in the Dock as a hard-edged square.
    LOGO="scripts/logo.png"
    if sips -g hasAlpha scripts/logo.png | grep -q "hasAlpha: no"; then
        LOGO="$(dirname "$ICONSET")/logo-shaped.png"
        swift scripts/shape-icon.swift scripts/logo.png "$LOGO" || LOGO="scripts/logo.png"
    fi
    for size in 16 32 128 256 512; do
        sips -z $size $size "$LOGO" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    echo "Note: no logo (scripts/logo.png), so the app has the plain icon."
fi
SUPPORT="${MEDIA_SHERPA_SUPPORT_WHATSAPP:-}"
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
    <key>CFBundleIdentifier</key><string>com.capturecampmedia.mediasherpa</string>
    <key>CFBundleExecutable</key><string>MediaSherpa</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Capture Camp Media</string>
    ${ICON_KEY}
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Media Sherpa copies photos from camera cards.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
    <key>MediaSherpaSupportWhatsApp</key><string>${SUPPORT}</string>
</dict>
</plist>
PLIST

# A local signature so macOS treats it as a normal app on this Mac.
codesign --force --sign - "$APP" >/dev/null
for old in "${OLD_NAMES[@]}"; do
    rm -rf ".build/${old}.app"
done

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/${APP_NAME}.app"
    for old in "${OLD_NAMES[@]}"; do
        rm -rf "$DEST/${old}.app"
    done
    cp -R "$APP" "$DEST/"
    echo "Done. ${APP_NAME} is in ${DEST}. Double-click it there, or drag it to the Dock."
else
    echo "Done. The app is at ${APP}."
fi
