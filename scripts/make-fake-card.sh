#!/bin/bash
# Makes a pretend camera card for testing: a disk image with a DCIM folder,
# mounted so the Mac treats it like an inserted card.
#
#   scripts/make-fake-card.sh                     # dummy files only
#   scripts/make-fake-card.sh ~/Desktop/samples   # also copies your sample photos onto it
#
# The image is saved in TestCards/ inside this project. To remove the card,
# eject FAKECARD in Finder like a real card. Never point this at a real card.
set -euo pipefail

cd "$(dirname "$0")/.."
SAMPLES="${1:-}"
NAME="FAKECARD"
IMAGE="TestCards/${NAME}.dmg"

if [ -d "/Volumes/${NAME}" ]; then
    echo "A ${NAME} volume is already mounted. Eject it in Finder first." >&2
    exit 1
fi

mkdir -p TestCards
rm -f "$IMAGE"
# Cameras format cards as FAT32 or exFAT; exFAT matches most modern cards.
hdiutil create -size 512m -fs ExFAT -volname "$NAME" -layout MBRSPUD "$IMAGE" >/dev/null
hdiutil attach "$IMAGE" >/dev/null

CARD="/Volumes/${NAME}"
FOLDER="${CARD}/DCIM/100TEST"
mkdir -p "$FOLDER"

if [ -n "$SAMPLES" ]; then
    # Copy (never move) the samples, numbered like a camera would.
    n=1
    find "$SAMPLES" -maxdepth 1 -type f ! -name '.*' -print0 | sort -z | while IFS= read -r -d '' f; do
        ext="${f##*.}"
        cp "$f" "$(printf '%s/IMG_%04d.%s' "$FOLDER" "$n" "$ext")"
        n=$((n + 1))
    done
else
    # Random bytes with camera-style names. Fine for copy and verify tests;
    # Milestone 2 onward needs real sample photos.
    for i in 1 2 3; do
        base=$(printf 'IMG_%04d' "$i")
        head -c 2000000 /dev/urandom > "$FOLDER/$base.CR3"
        head -c 500000 /dev/urandom > "$FOLDER/$base.JPG"
    done
    head -c 300000 /dev/urandom > "$FOLDER/IMG_0004.HEIC"
    head -c 5000000 /dev/urandom > "$FOLDER/MVI_0005.MP4"
    head -c 20000 /dev/urandom > "$FOLDER/MVI_0005.THM"
    # Random bytes have no capture date, so the app uses each file's modified
    # date. The clip says it was shot on 14 October; its .THM follows the clip.
    touch -t 202610140905 "$FOLDER/MVI_0005.MP4"

    # The camera's counter started again in a new folder: a second, different
    # IMG_0001 (RAW+JPEG) shot the same day. It gets "-2" instead of a clash.
    sleep 1
    mkdir -p "${CARD}/DCIM/101TEST"
    head -c 2000000 /dev/urandom > "${CARD}/DCIM/101TEST/IMG_0001.CR3"
    head -c 500000 /dev/urandom > "${CARD}/DCIM/101TEST/IMG_0001.JPG"
fi

# Something that should be ignored, like the files cameras leave behind.
mkdir -p "${CARD}/MISC"
echo "camera settings" > "${CARD}/MISC/SETTINGS.DAT"

echo "Fake card mounted at ${CARD}:"
ls -lR "${CARD}/DCIM"
