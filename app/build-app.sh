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
VERSION="0.3.0"
# Sparkle compares CFBundleVersion, not the marketing string, and refuses to
# offer an update unless it increases. Derived from VERSION rather than kept by
# hand — a build number that has to be remembered is one that eventually is not,
# and the symptom is silence: updates simply stop being offered. Each component
# is allowed two digits, so 0.3.0 is 300 and 0.3.1 is 301.
BUILD="$(awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }' <<<"$VERSION")"
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

# ── Sparkle ───────────────────────────────────────────────────────────────────
# SwiftPM links the framework but never embeds it, because it has no concept of
# the bundle this script assembles by hand. Left out, the app dies at launch
# with a dyld error naming a path inside .build that no other Mac has.
#
# The universal slice, not the arm64 one SwiftPM leaves in its build directory:
# a release has to run on Intel too.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d \
    -path "*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "error: Sparkle.framework not found — run 'swift build' first" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
# -R rather than -a: the symlinks inside the framework must stay symlinks, and
# the extended attributes carrying the upstream signature must not come along,
# since every piece is re-signed below anyway.
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

# SwiftPM builds executables with a single rpath of @executable_path/../lib,
# which is where nothing in a .app bundle lives. Without this the app dies at
# launch with "Library not loaded: @rpath/Sparkle.framework" — verified, not
# guessed. Done here rather than with linker flags in Package.swift so that
# `swift build` and `swift test` keep working against the framework SwiftPM
# already resolves, and before signing, because editing a Mach-O header
# invalidates whatever signature it had.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
                  "$APP/Contents/MacOS/SkyGlance" 2>/dev/null

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
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <!-- Sparkle. The feed is served from the default branch rather than a
         separate host, so publishing an update is a commit in this repo and
         cannot drift away from the tag it describes. SUPublicEDKey is the
         public half of a keypair whose private half lives only in the release
         machine's login keychain: lose it and existing installs can never be
         updated again, because they will refuse anything it did not sign. -->
    <key>SUFeedURL</key>
        <string>https://raw.githubusercontent.com/darshjoshi/skyglance-mac/main/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>tcRcC3UdLuajNzi9FSLLRcGwnye1VdbS6U2Z1Dx1bKQ=</string>
    <!-- SUEnableAutomaticChecks is deliberately absent. Setting it true turns on
         background checks without asking; leaving it out makes Sparkle ask once,
         and remember the answer. An app that documents every request it makes
         should not quietly add one. -->
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
    # Sparkle is signed from the inside out, and deliberately not with --deep,
    # which Sparkle's own documentation warns against: it re-signs the XPC
    # services with the wrong flags and they stop being able to install
    # anything. Each piece is nested code in its own right and has to carry its
    # own signature before whatever contains it is sealed over the top.
    SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$SPARKLE_IN_APP/XPCServices/Installer.xpc"
    # Downloader.xpc ships entitlements of its own; re-signing without
    # preserving them removes the sandbox it deliberately runs inside.
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
             --sign "$IDENTITY" "$SPARKLE_IN_APP/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$SPARKLE_IN_APP/Updater.app"
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$SPARKLE_IN_APP/Autoupdate"
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
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

    # ── Disk image ────────────────────────────────────────────────────────────
    # What someone who has never used Homebrew downloads.
    #
    # The Applications symlink next to the app is the whole point. A zip leaves
    # the app wherever the browser put it, and macOS then runs it from a
    # randomised read-only AppTranslocation path — measured, not assumed — which
    # silently breaks Launch at Login, because SMAppService registers whichever
    # path the app is running from. Dragging it across in Finder is what clears
    # the quarantine flag that causes that, so the disk image exists to make
    # that drag the obvious thing to do.
    #
    # The app going in has already been stapled above, and the image is stapled
    # separately below: the image has to pass Gatekeeper when it is mounted, and
    # the app has to pass again once it has been copied out of it, offline.
    DMG="build/SkyGlance-${VERSION}.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    # Copied rather than moved: build/SkyGlance.app stays where the rest of the
    # script — and anyone running the app locally — expects to find it.
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"

    # Built read-write first so the window can be arranged, then compressed.
    # Arranging it is not decoration: unarranged, Finder drops the two icons in
    # alphabetical order, which puts Applications on the left and the app on the
    # right — so the one gesture the image exists to suggest runs backwards.
    RW="build/SkyGlance-rw.dmg"
    rm -f "$RW"
    hdiutil create -volname "SkyGlance" -srcfolder "$STAGE" \
                   -ov -format UDRW -quiet "$RW"
    rm -rf "$STAGE"
    hdiutil attach "$RW" -nobrowse -quiet

    # Finder is the only thing that writes the .DS_Store these settings live in.
    # `|| true`: an unarranged image still installs correctly, so a scripting
    # failure here — a locked screen, no automation permission — must not fail a
    # release that is otherwise sound.
    osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "SkyGlance"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 760, 530}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "SkyGlance.app" of container window to {150, 190}
        set position of item "Applications" of container window to {410, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    # Give Finder a moment to flush the .DS_Store before the volume goes away.
    sleep 2
    hdiutil detach "/Volumes/SkyGlance" -quiet
    # UDZO is the compressed read-only format every Mac has opened since 10.4.
    hdiutil convert "$RW" -format UDZO -o "$DMG" -quiet
    rm -f "$RW"

    # Sign the image itself, not just what it contains. Apple notarises the
    # outermost thing you hand out, and an unsigned image would fail that.
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    echo "submitting the disk image to Apple…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    # `--type open --context context:primary-signature` is how Gatekeeper judges
    # a downloaded disk image; `--type execute` answers a different question and
    # would pass on an image nobody can open.
    spctl --assess --type open --context context:primary-signature \
          --verbose=2 "$DMG"
    echo "disk image ready: $DMG"
fi
