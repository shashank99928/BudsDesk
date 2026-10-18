#!/bin/bash
#
# Packages BudsDesk.app into a drag-to-install disk image.
#
# The image is built in two passes: a writable image is mounted, filled, and styled with a Finder
# window (size, background, icon positions, hidden toolbar), then converted to a compressed
# read-only DMG. The background art lives *inside* the image, so it survives being downloaded and
# opened on another Mac — a background that is only referenced by path from the layout script
# arrives as a blank window on someone else's machine.
#
#   ./make-dmg.sh            build release and package it
#   ./make-dmg.sh debug      same, with a debug build
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=${1:-release}
APP_NAME="BudsDesk"
VOL_NAME="BudsDesk"
APP="$APP_NAME.app"
DIST="dist"
OUT_DMG="$DIST/$APP_NAME.dmg"
RW_DMG="$DIST/rw.dmg"
VOLUME="/Volumes/$VOL_NAME"
BACKGROUND="Resources/dmg-background.png"

# --- 1. Build the app -----------------------------------------------------------------
./build.sh "$CONFIG"

# --- 2. Background art ----------------------------------------------------------------
# Generated rather than checked in: a checked-in PNG cannot be re-tuned without a drawing tool,
# and carries a file-provenance question that generated art does not.
if [ ! -f "$BACKGROUND" ]; then
    echo "generating disk-image background…"
    swift Tools/make-dmg-background.swift
fi

# --- 3. Work directory ----------------------------------------------------------------
mkdir -p "$DIST"
rm -f "$OUT_DMG" "$RW_DMG"
hdiutil detach "$VOLUME" >/dev/null 2>&1 || true

cleanup() {
    hdiutil detach "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 4. Create and mount a writable image ---------------------------------------------
# A generous fixed size rather than a measured one: the app is a few megabytes and the slack
# costs nothing once the image is compressed.
hdiutil create -size 100m -fs HFS+ -volname "$VOL_NAME" -ov "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -mountpoint "$VOLUME" >/dev/null

# --- 5. Fill it -----------------------------------------------------------------------
cp -R "$APP" "$VOLUME/"
ln -s /Applications "$VOLUME/Applications"
mkdir -p "$VOLUME/.background"
cp "$BACKGROUND" "$VOLUME/.background/"
[ -f Resources/dmg-background@2x.png ] && cp Resources/dmg-background@2x.png "$VOLUME/.background/"

# A custom icon for the mounted volume, and therefore for the .dmg file itself.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$VOLUME/.VolumeIcon.icns"
    SetFile -a C "$VOLUME" 2>/dev/null || true
fi

# --- 6. Style the window with Finder --------------------------------------------------
# Finder scripting can block indefinitely if Automation access has not been granted, so it runs
# under a watchdog: a DMG with the default layout is still a working installer, and a build that
# hangs forever is not a build.
run_osascript() {
    osascript "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.5
        waited=$((waited + 1))
        if [ "$waited" -ge 60 ]; then
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "warning: Finder did not respond — shipping the image unstyled" >&2
            return 1
        fi
    done
    wait "$pid"
}

# The script goes in a file rather than on stdin: a backgrounded command gets /dev/null as stdin
# in a non-interactive shell, so `osascript -` would read an empty script.
SCRIPT_FILE=$(mktemp -t budsdesk-dmg)
cat > "$SCRIPT_FILE" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set volumePath to item 2 of argv
    set appName to item 3 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 860, 540}
            set opts to the icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 128
            set text size of opts to 13
            set background picture of opts to (POSIX file (volumePath & "/.background/dmg-background.png"))
            set position of item appName of container window to {165, 205}
            set position of item "Applications" of container window to {495, 205}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT

run_osascript "$SCRIPT_FILE" "$VOL_NAME" "$VOLUME" "$APP_NAME" || true
rm -f "$SCRIPT_FILE"

# Finder writes the window layout to the volume's .DS_Store asynchronously; detaching the instant
# the script returns loses it, and the image ships with the default layout.
sync
sleep 2

# --- 7. Convert to a compressed read-only image ---------------------------------------
hdiutil detach "$VOLUME" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null
rm -f "$RW_DMG"

# --- 8. Notarise (optional) -----------------------------------------------------------
# Gatekeeper refuses to open a downloaded, unnotarised image on a Mac that has never seen it.
# Give notarytool a stored keychain profile (xcrun notarytool store-credentials <profile>) and
# name it here; the ticket is stapled to the image so it also validates offline. Requires
# SIGN_IDENTITY to have been set at build time — notarisation rejects an ad-hoc signature.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "notarising with profile '$NOTARY_PROFILE' (this can take a few minutes)…"
    xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT_DMG"
fi

echo "install:  open \"$OUT_DMG\""
echo "release:  gh release upload <tag> \"$OUT_DMG\" --clobber"
echo "          → https://github.com/shashank99928/BudsDesk/releases/latest/download/BudsDesk.dmg"
