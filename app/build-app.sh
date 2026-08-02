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
VERSION="0.2.0"
cd "$(dirname "$0")"

# Worked out before the Info.plist is written, because LSUIElement depends on it
# (see the comment on that key). A Developer ID is used when one is present and
# ad-hoc otherwise, so cloning and building works with no Apple account.
# Override with SKYGLANCE_SIGN_IDENTITY.
IDENTITY="${SKYGLANCE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
                | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
# `SKYGLANCE_SIGN_IDENTITY=-` is codesign's spelling of "ad-hoc", so normalise it
# to empty. Otherwise it reads as a real certificate and the build would take the
# Dock flash for a location button that cannot work.
[ "$IDENTITY" = "-" ] && IDENTITY=""

# Release builds ship to strangers, so they must run on Intel too. Debug builds
# are for the person sitting here, so keep them fast and single-architecture.
ARCHS=()
if [ "$CONFIG" = "release" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
fi

# `${ARCHS[@]+"${ARCHS[@]}"}` rather than `"${ARCHS[@]}"`: bash 3.2 — still the
# default /bin/bash on macOS — treats an empty array as unbound under `set -u`,
# so the plain form aborts every debug build with "ARCHS[@]: unbound variable".
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/SkyGlance"

APP="build/SkyGlance.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SkyGlance"

# LSUIElement=false is what lets Location Services register the app, but it also
# costs a Dock icon flash at launch — worth paying only when the location button
# can actually work, which needs a Developer ID too.
if [ -n "$IDENTITY" ]; then LSUIELEMENT="false"; else LSUIELEMENT="true"; fi

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
    <!-- False on a signed build, true on an ad-hoc one — see $LSUIELEMENT above.
         Either way AgentDelegate calls setActivationPolicy(.accessory) at
         launch, so the running app has no Dock icon and no app menu regardless.
         The key only decides whether macOS registers the app with Location
         Services: with it true, requestWhenInUseAuthorization() shows no dialog
         and the status stays .notDetermined forever. Measured across all four
         combinations, "Use My Location" works only with LSUIElement=false AND a
         Developer ID; the other three fail silently. False costs a ~0.5s Dock
         icon flash at launch, which is only worth paying when the location
         button can actually work. -->
    <key>LSUIElement</key>             <${LSUIELEMENT}/>
    <!-- Shown verbatim in the system prompt during first-run setup. Typing
         coordinates by hand is always offered as an alternative. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>SkyGlance uses your location once, to work out which aircraft are overhead. Your exact position stays on this Mac; only a position rounded to about a kilometre is sent to the flight feeds.</string>
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
#
# `--options runtime` enables the hardened runtime, which stops another process
# injecting a library into this one or steering it with DYLD_* variables. The
# app needs no entitlement exemptions, so it costs nothing, and notarisation
# refuses anything without it.
#
# $IDENTITY was resolved at the top, because the Info.plist depends on it.
# Only a signed build can notarise, and only a signed build gets Location
# Services, so "Use My Location" is expected to fail on an ad-hoc build.
if [ -n "$IDENTITY" ]; then
    # --timestamp contacts Apple's timestamp server; notarisation rejects a
    # signature without one, and it is what keeps the app valid after the
    # certificate itself expires.
    echo "signing as: $IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "note: no Developer ID found — signing ad-hoc."
    echo "      the app will run, but Gatekeeper will warn on download and"
    echo "      'Use My Location' will not work. Both need a Developer ID."
    codesign --force --options runtime --sign - "$APP"
fi

# And prove it, rather than trusting that the command above did anything.
codesign --verify --strict "$APP"
# Verify the hardened runtime specifically: --verify passes on a signature that
# has no such flag, so it would not notice this silently regressing.
#
# Captured to a variable rather than piped: `codesign | grep -q` exits 141 under
# `set -o pipefail` even when the pattern matches, because grep closes the pipe
# on the first hit and codesign dies of SIGPIPE. That reports a missing flag on
# a signature that has one — a check failing for a reason unrelated to the thing
# it checks, which is the exact bug class this script exists to prevent.
signature=$(codesign --display --verbose=2 "$APP" 2>&1)
if ! grep -q 'flags=.*runtime' <<<"$signature"; then
    echo "error: hardened runtime flag missing from the signature" >&2
    echo "$signature" >&2
    exit 1
fi

echo "built $APP ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    echo "  architectures: $(lipo -archs "$APP/Contents/MacOS/SkyGlance")"
fi

# ── Notarisation ──────────────────────────────────────────────────────────────
# `./build-app.sh release notarize` submits the app to Apple and staples the
# resulting ticket into the bundle. Stapling matters: without it Gatekeeper has
# to ask Apple's servers on first launch, so a machine that is offline — or
# behind a filter — still shows the warning.
#
# Credentials come from the keychain, never from the repo. Create the profile
# once with:
#   xcrun notarytool store-credentials "skyglance" \
#       --apple-id <you> --team-id <team> --password <app-specific-password>
if [ "${2:-}" = "notarize" ]; then
    if [ -z "$IDENTITY" ]; then
        echo "error: cannot notarise an ad-hoc signed app — a Developer ID is required" >&2
        exit 1
    fi
    PROFILE="${SKYGLANCE_NOTARY_PROFILE:-skyglance}"
    ZIP="build/SkyGlance-notarize.zip"
    # notarytool takes an archive, not a bundle. ditto rather than `zip -r`,
    # which can drop the extended attributes the signature lives in.
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    echo "submitting to Apple (this usually takes a few minutes)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

    # Staple into the bundle, then prove Gatekeeper actually accepts it. Without
    # this check a failed staple would leave a bundle that looks fine locally
    # and warns on someone else's Mac.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm -f "$ZIP"
    echo "notarised and stapled"
fi
