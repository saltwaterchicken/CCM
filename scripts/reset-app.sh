#!/bin/bash
# Puts Media Sherpa back to a first run on this Mac, for testing: the tutorial
# opens by itself and the settings are the defaults.
#
#   scripts/reset-app.sh            # reset; the license key and keyboard shortcuts stay
#   scripts/reset-app.sh --license  # also remove the key, so it asks for one, as on a new Mac
#   scripts/reset-app.sh --restore  # put back what the latest reset moved aside
#   scripts/reset-app.sh --restore 2026-11-02-151634  # or an earlier one, by its folder name
#
# Deleting the preferences file in Finder doesn't work: macOS holds preferences
# in memory (cfprefsd) and writes them back. `defaults` goes through it.
#
# Nothing is lost: a copy goes to ~/Library/Application Support/Media Sherpa Resets
# first. Cards, the destination and the Server aren't touched.
set -euo pipefail

DOMAIN="com.capturecampmemories.cardingest"
SWIFT_RUN_DOMAIN="CardIngest"   # the preferences `swift run` uses
PROCESS="CardIngest"
LIBRARY="$HOME/Library/Application Support"
SUPPORT="$LIBRARY/Media Sherpa"
RESETS="$LIBRARY/Media Sherpa Resets"
# Before the app was renamed these were "Card Ingest" and "Card Ingest Resets".
# Move them to the new names, as the app does, so nothing is left behind.
[ -d "$LIBRARY/Card Ingest" ] && [ ! -e "$SUPPORT" ] && mv "$LIBRARY/Card Ingest" "$SUPPORT"
[ -d "$LIBRARY/Card Ingest Resets" ] && [ ! -e "$RESETS" ] && mv "$LIBRARY/Card Ingest Resets" "$RESETS"
KEEP_KEYS=(licenseKey licenseLastSeen NSUserKeyEquivalents)
PREFS_COPY="Preferences.plist"

MODE="reset"
case "${1:-}" in
    "") ;;
    --license) KEEP_KEYS=(NSUserKeyEquivalents) ;;
    --restore) MODE="restore"; CHOSEN="${2:-}" ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# Asks the app to quit rather than forcing it, so a copy in progress can say no.
quit_app() {
    pgrep -x "$PROCESS" >/dev/null || return 0
    echo "Quitting Media Sherpa…"
    osascript -e "quit app id \"$DOMAIN\"" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -x "$PROCESS" >/dev/null || return 0
        sleep 0.5
    done
    echo "Media Sherpa is still running, so nothing was changed. Quit it and run this again." >&2
    exit 1
}

confirm() {
    read -r -p "$1 [y/N] " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Nothing was changed."; exit 0; }
}

if [ "$MODE" = "restore" ]; then
    if [ -n "${CHOSEN:-}" ]; then
        FROM="$RESETS/$CHOSEN"
    else
        FROM="$(ls -1d "$RESETS"/*/ 2>/dev/null | sort | tail -1)"
        FROM="${FROM%/}"
    fi
    [ -n "$FROM" ] && [ -d "$FROM" ] || { echo "No reset to restore${CHOSEN:+ called $CHOSEN}. These are kept:" >&2; ls -1 "$RESETS" >&2 2>/dev/null; exit 1; }
    confirm "Replace the current settings and preferences with $(basename "$FROM")?"
    quit_app
    if [ -f "$FROM/$PREFS_COPY" ]; then
        defaults delete "$DOMAIN" 2>/dev/null || true
        defaults import "$DOMAIN" "$FROM/$PREFS_COPY"
    fi
    mkdir -p "$SUPPORT"
    for name in Settings.plist "My Keywords.txt"; do
        rm -f "$SUPPORT/$name"
        [ -f "$FROM/$name" ] && cp -p "$FROM/$name" "$SUPPORT/$name"
    done
    echo "Restored from $FROM"
    exit 0
fi

confirm "Reset Media Sherpa to a first run? (A copy of the current setup is kept.)"
quit_app

BACKUP="$RESETS/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"     # the preferences hold the license key

KEPT="$BACKUP/.kept.plist"
plutil -create xml1 "$KEPT"
if defaults read "$DOMAIN" >/dev/null 2>&1; then
    defaults export "$DOMAIN" "$BACKUP/$PREFS_COPY"
    for key in "${KEEP_KEYS[@]}"; do
        if value="$(plutil -extract "$key" xml1 -o - "$BACKUP/$PREFS_COPY" 2>/dev/null)"; then
            plutil -insert "$key" -xml "$value" "$KEPT"
        fi
    done
    defaults delete "$DOMAIN" 2>/dev/null || true   # says no if it's already empty
fi
defaults delete "$SWIFT_RUN_DOMAIN" 2>/dev/null || true
defaults import "$DOMAIN" "$KEPT"
rm -f "$KEPT"

for name in Settings.plist "My Keywords.txt"; do
    [ -f "$SUPPORT/$name" ] && mv "$SUPPORT/$name" "$BACKUP/$name"
done

echo "Reset. Open Media Sherpa and the tutorial will start."
echo "Your old setup is in $BACKUP"
echo "To put it back: scripts/reset-app.sh --restore $(basename "$BACKUP")"
