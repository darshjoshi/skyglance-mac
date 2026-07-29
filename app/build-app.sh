#!/bin/bash
# Wrap the SwiftPM executable in a proper .app bundle so it behaves like a real
# menu bar agent (no Dock icon, correct bundle identity for notifications).
#
#   ./build-app.sh            release, universal
#   ./build-app.sh debug      faster build, current architecture only
#
# This is the only supported way to run SkyGlance. `swift run SkyGlance` produces
# a bare executable with no Info.plist, and macOS refuses notifications to a
# process with no bundle identity.
set -euo pipefail

CONFIG="${1:-release}"
VERSION="0.1.0"
cd "$(dirname "$0")"

# Release builds ship to strangers, so they must run on Intel too. Debug builds
# are for the person sitting here, so keep them fast and single-architecture.
ARCHS=()
if [ "$CONFIG" = "release" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCHS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/SkyGlance"

APP="build/SkyGlance.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SkyGlance"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SkyGlance</string>
    <key>CFBundleDisplayName</key>     <string>SkyGlance</string>
    <key>CFBundleIdentifier</key>      <string>com.darshjoshi.skyglance</string>
    <key>CFBundleExecutable</key>      <string>SkyGlance</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.travel</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
    <!-- Shown verbatim in the system prompt during first-run setup. Typing
         coordinates by hand is always offered as an alternative. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>SkyGlance uses your location once, to work out which aircraft are overhead. It is stored on this Mac and never sent anywhere.</string>
    <key>NSHumanReadableCopyright</key><string>Free ADS-B data from adsb.lol (ODbL), airplanes.live and adsb.fi</string>
</dict>
</plist>
PLIST

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: AppIcon.icns missing — the notification prompt will show a blank icon" >&2
fi

# Ad-hoc signature. Enough to run locally and via Homebrew; a Developer ID is
# only needed to make a plain download open without a Gatekeeper warning.
#
# This used to be `2>/dev/null || echo ...`, which discarded the reason for a
# failure AND converted it into a success under `set -e` — so the script could
# report "built" having produced an unsigned bundle, which on Apple silicon is
# immediately fatal with no clue why. Let it fail loudly instead.
codesign --force --sign - "$APP"

# And prove it, rather than trusting that the command above did anything.
codesign --verify --strict "$APP"

echo "built $APP ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/SkyGlance")"
fi
