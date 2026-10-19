#!/bin/bash
# Builds BudsDesk.app.
#
# Compiles with the Command Line Tools; an installed Xcode.app is needed only for its SwiftUI
# macro plugin (see Package.swift). Xcode need not be selected with xcode-select.
#
#   ./build.sh            release   — what ships
#   ./build.sh debug      debug
#
# Both configurations are built and checked the same way. A check that only runs in debug is a
# check that does not cover the binary users run.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="BudsDesk.app"

swift build -c "$CONFIG"
BINARY=$(swift build -c "$CONFIG" --show-bin-path)/BudsDesk

# The source-level guard, first, because it is the cheapest thing that can fail and the failure
# it catches is invisible at runtime: SwiftUI draws *nothing* for an SF Symbol name the OS does
# not know, and reports no error. A typo ships as an empty gap where an icon should be.
if ! swift Tools/check-symbols.swift; then
    echo "error: SF Symbol check failed" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BudsDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The capability registry ships *inside* the bundle. It is read at runtime rather than compiled
# in, so that adding a model stays a file and not a build — which means the file has to travel
# with the app. RegistryLocation finds it here; see that file for the full search order.
mkdir -p "$APP/Contents/Resources/devices"
cp devices/*.json "$APP/Contents/Resources/devices/"
cp devices/README.md "$APP/Contents/Resources/devices/README.md"

# The bundle works without an icon; it just looks unfinished in the Dock and in Finder.
# Regenerate with `swift Tools/make-icon.swift` if this is missing.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: Resources/AppIcon.icns missing — run: swift Tools/make-icon.swift" >&2
fi

# Ad-hoc signature by default. It is enough for a user who downloads the app and confirms it
# once in System Settings, and it is what an unnotarised build can honestly claim.
#
# For distribution, set SIGN_IDENTITY to a "Developer ID Application: …" identity. That signs
# with the hardened runtime and a secure timestamp, which is what notarisation requires; see
# make-dmg.sh for the notarise-and-staple step.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    echo "signed with $SIGN_IDENTITY"
else
    codesign --force --sign - "$APP"
fi

# The protocol checks, run against the bundle that was just built, in the configuration that
# was just built. Release included, since that is what ships.
if ! "./$APP/Contents/MacOS/BudsDesk" --selfcheck; then
    echo "error: protocol self-check failed" >&2
    exit 1
fi

# And the registry the bundle actually carries, read the way the app reads it — from inside the
# bundle rather than from ./devices, which is the directory a developer is most likely to have
# edited. This is the check that catches a registry that is valid on disk and absent in the app.
if ! "./$APP/Contents/MacOS/BudsDesk" --profiles >/dev/null; then
    echo "error: the bundled registry does not load" >&2
    exit 1
fi

# The window, drawn by this binary and compared with the drawings in the repository. A layout that
# nobody looked at is otherwise perfectly valid SwiftUI that just looks wrong — a clipped label, a
# control that fell out of its row — and nothing else in this build can see that. The site's
# screenshot is one of these files, so the picture a visitor sees is a picture that passed.
#
# Run `./BudsDesk.app/Contents/MacOS/BudsDesk --render` after an intended change, and look at it.
if ! "./$APP/Contents/MacOS/BudsDesk" --compare .; then
    echo "error: the window no longer matches the drawings in the repository" >&2
    exit 1
fi

echo "built $APP"
echo "run:  open \"$APP\"     (or: \"./$APP/Contents/MacOS/BudsDesk\"  to see stderr)"
