<div align="center">
<img src="docs/images/icon.png" width="96" alt="">

# SkyGlance

**A macOS menu bar app that tells you what is flying over your head right now — and taps you on the shoulder when something worth looking up for is about to pass.**

No API key. No account. No subscription. Nothing to run in the background.

<img src="docs/images/panel.png" width="380" alt="The SkyGlance panel: a sky dome with aircraft drawn as heading-rotated glyphs with motion trails, above a list of the nearest aircraft.">

</div>

---

## What it does

**The count is always in your menu bar.** `✈ 23` means twenty-three aircraft within 60 nautical miles.
When something is actually overhead it says so — `✈ 23 · B738 55°` — and when one is inbound it
counts down: `✈ 23 · A320 25s`.

**The dome is the sky, not a map.** The centre is straight up, the rim is the horizon, north is up.
A map answers "where is it going"; this answers "where do I point my face". Aircraft are drawn as
glyphs rotated to their actual heading, with a trail showing where they came from — recorded from
real observations, not extrapolated.

The radial scale is deliberately non-linear. Measured over a real location, **42 of 42 aircraft sat
below 10° elevation**, which a linear projection crushes into the outer 11% of the disc. Here the
0–10° band gets the outer 46%, because that is where the traffic actually is.

**It interrupts you rarely, and honestly.** Four things earn an alert: rare or unusual types,
helicopters, anything big and low, and emergency squawks. A budget caps how often, with per-category
lanes so a busy morning of routine arrivals cannot spend the whole day and silently drop a 747 at
noon. If it is too dark or too overcast to see, the alert says *"passed overhead · too dark to see"*
rather than telling you to look at nothing.

**Alerts arrive as a card that unfolds from the menu bar.** Not a banner in the corner — the
aircraft appears under the ✈ it came from, with a photograph, the route, and the one line that
matters while something is passing: *"Look SE, 35° up"*. It fades by itself after twelve seconds,
holds open if you hover it, and opens the full panel if you click.

The card only appears if you are actually at the Mac; if you are away, or the screen is locked, the
alert becomes a normal notification instead so it waits for you in Notification Center. Never both.
VoiceOver and Switch Control users always get the notification, because a card that never takes
focus is not something a screen reader can reach.

**Popups have their own, looser budget** than notifications — a card that fades on its own is
cheaper to ignore than a banner that stacks up. If your sky is quiet and you want more of them,
**Frequent Popups** in the `⋯` menu roughly doubles the volume, halves the gap, and stops holding
back after dark. Near a busy approach path, leave it off.

**Tap an aircraft for the rest.** Operator, route, registration, and a photograph — roughly six in
seven aircraft resolve.

---

## Install

### Homebrew (recommended)

```bash
brew install --cask darshjoshi/tap/skyglance
```

That is the whole thing — the cask clears the quarantine flag for you in a `postflight` step, so the
app just opens.

<details>
<summary>Why that step exists</summary>

SkyGlance is signed ad-hoc, not notarised with a $99/year Apple Developer ID. macOS attaches a
quarantine flag to anything downloaded, and Gatekeeper refuses to open an un-notarised app while that
flag is set — showing *"Apple could not verify SkyGlance is free of malware"*, whose only buttons are
**Move to Trash** and **Done**. Apple removed the old Control-click → Open shortcut in macOS 15, and
Homebrew's `--no-quarantine` flag is rejected outright by current versions (`Error: invalid option`),
so the cask runs `xattr -dr com.apple.quarantine` after install instead.

You can verify exactly what it does — it is
[eight lines](https://github.com/darshjoshi/homebrew-tap/blob/main/Casks/skyglance.rb) of readable
Ruby. If you would rather not trust it, build from source below; a locally compiled app is never
quarantined.

</details>

### Download the app

Grab `SkyGlance.app.zip` from [Releases](https://github.com/darshjoshi/skyglance-mac/releases),
unzip it, move it to `/Applications`, and clear the quarantine flag yourself — Homebrew is not there
to do it for you:

```bash
xattr -dr com.apple.quarantine /Applications/SkyGlance.app
```

Skip that and macOS will refuse to open it. If it already has, the recovery is **System Settings →
Privacy & Security**, scroll to Security, **Open Anyway**, authenticate, then launch again.

### Build it yourself — no Gatekeeper friction at all

An app you compiled is never quarantined, so this path needs none of the above.

Needs Xcode 15 or newer.

```bash
git clone https://github.com/darshjoshi/skyglance-mac.git
cd skyglance-mac/app
./build-app.sh
open build/SkyGlance.app
```

> `swift run SkyGlance` **does not work.** It produces a bare executable with no `Info.plist`, and
> macOS refuses notifications to a process with no bundle identity. `build-app.sh` is the only
> supported path — the app will tell you so rather than crashing.

**Requires macOS 13 Ventura or newer.** Release builds are universal (Apple silicon and Intel).

---

## First run

<img src="docs/images/setup.png" width="360" align="right" alt="The setup window asking where you watch the sky, with a Use My Location button, a coordinate field, and an all-around or one-direction choice.">

SkyGlance asks two questions and then gets out of the way.

**Where you are.** Type your coordinates, or try *Use My Location*. Your exact position is stored on
your Mac and used for the geometry; what goes to the flight feeds is rounded to about a kilometre.
[The details are below](#privacy).

> **Use My Location does not work in the released build**, and the app tells you so rather than
> spinning. SkyGlance is signed ad-hoc, with no Apple Team ID, so macOS never registers it with
> Location Services — no permission dialog appears and the app never even shows up under Privacy &
> Security › Location Services. Fixing it needs the same $99/year Developer ID that would remove the
> Gatekeeper warning. Typing coordinates works everywhere: right-click your spot in Apple Maps and
> choose *Copy Coordinates*, or read them off any map site.

**What you can see from there.** *All around* by default. Choose a direction if a building or a hill
blocks half your sky: aircraft outside the arc still appear, dimmed, but never trigger an alert.

Notifications are requested at the end of setup, not at launch, and if you decline the panel says so
instead of quietly counting alerts that were never delivered.

Both are changeable later from **Settings…** in the panel.

<br clear="right">

---

## How it works

Three independent ADS-B feeds are polled every three seconds and **merged**, not failed over —
unioned by ICAO hex with the freshest position winning. Measured, that is worth about 15% more
aircraft than any single source, and it means one going down is invisible to you.

Each source has its own rate limiter (1 req/sec) and a circuit breaker that opens for 30 seconds
after three consecutive failures. When everything is down the app says so; a quiet sky and a broken
app never render the same way. That principle is load-bearing here — most of the bugs found while
building this were a failure state that looked exactly like a normal one, and they are all written
up in [docs/ROADMAP.md](docs/ROADMAP.md).

Enrichment (routes, aircraft types, photographs) happens **only** when you select an aircraft or an
alert fires — never for a whole list on every poll — and results are cached permanently, including
misses.

More depth: [architecture](docs/ARCHITECTURE.md) · [the geometry](docs/OVERHEAD-DETECTION.md) ·
[the free stack](docs/FREE-STACK.md) · [what every source costs](docs/COVERAGE-AND-COST.md) ·
[the full landscape, paid and free](docs/RESEARCH.md)

---

## Data sources

Every one is free, keyless, and run by volunteers.

| Source | Provides | Terms |
|---|---|---|
| [adsb.lol](https://www.adsb.lol) | Live positions | **ODbL 1.0** — attribution required |
| [airplanes.live](https://airplanes.live) | Live positions | Non-commercial |
| [adsb.fi](https://adsb.fi) | Live positions | Community-run |
| [adsbdb.com](https://www.adsbdb.com) | Types and routes | Free |
| [hexdb.io](https://hexdb.io) | Types and routes (fallback) | Free |
| [planespotters.net](https://www.planespotters.net) | Photographs | Photographer credit required |
| [Open-Meteo](https://open-meteo.com) | Cloud cover and daylight | Free, non-commercial |

**If you fork this, be polite.** These are volunteer-run services with no SLA and no funding. Keep
the rate limiting, keep the caching, and put a real contact URL in the `User-Agent` — planespotters
rejects generic ones outright, which is the whole reason that string exists.

---

## Privacy

There is no account, no analytics, no telemetry, and no server of mine anywhere in this. But
"what is flying over *me*" cannot be answered without telling somebody roughly where you are, and
you should know exactly who gets what.

**Your location goes to four third parties.** The three ADS-B feeds need a search centre, and
Open-Meteo needs one to say whether it is cloudy. That is unavoidable — it is how these keyless APIs
work.

**It is rounded to two decimal places (~1.1 km) first.** Your exact coordinate never leaves the
machine. It is kept locally, where it is used to compute the bearing and elevation for the dome, so
the display stays precise:

```
stored on your Mac:  51.47212, -0.45431
sent to the feeds:   51.47,    -0.45
```

Requests carry a 60 nm (111 km) radius, so a sub-kilometre shift in the centre changes which
aircraft come back by well under 1% — the coarsening costs you nothing you can see.

**The poll is continuous.** Every three seconds while the app runs. Even coarsened, that tells those
services a neighbourhood and the hours your Mac is awake. Nothing identifies *you* — no account, no
device ID, no cookie — but the requests do come from your IP address, and the `User-Agent` names
this project (`SkyGlance/0.1 (+https://github.com/…)`), which planespotters requires.

**Selecting an aircraft reveals which one you looked at.** Type, route, and photo lookups only fire
when you deliberately tap something or an alert triggers — never for the whole list on every poll —
so adsbdb, hexdb, and planespotters see a handful of aircraft a day, not your whole sky.

**A popup asks for more than a notification does.** A banner needs only the route; a card also wants
the photograph, which means a registration lookup, a photo lookup, and then fetching the image
itself — up to about three requests instead of one, and popups are allowed to fire more often than
notifications. To keep that from becoming a burst against services that are run by volunteers and
have no rate limiting of their own, requests are spaced at least half a second apart **per host**,
and every result is cached permanently including the misses. Turning on **Frequent Popups** roughly
doubles this traffic.

**What stays on your Mac.** Your exact coordinate and viewing arc live in
`~/Library/Preferences/com.darshjoshi.skyglance.plist`; the enrichment cache lives in
`~/Library/Application Support/SkyGlance`. `brew uninstall --zap skyglance` removes both.

If you want none of this, don't run it — an app that answers this question without sending a
location somewhere isn't possible.

---

## Development

```bash
cd app
swift test              # 85 tests, fully offline and deterministic
./build-app.sh debug    # fast single-architecture build
```

There are no external package dependencies and the build needs no network.

A menu bar panel cannot be screenshotted on a sleeping or headless display, so the app can render
itself offscreen:

```bash
./build/SkyGlance.app/Contents/MacOS/SkyGlance --render out.png --dark \
    --at "51.4700, -0.4543" --warmup 150
```

`--at` polls somewhere else without touching your settings, and `--warmup` waits long enough for the
motion trails to accumulate — they are built from recorded polls and are invisible in a cold render.
The screenshot at the top of this page was made with exactly that command.

`reference/` holds a dependency-free Node implementation of the same architecture. The Mac app does
not use it and you do not need Node — see [reference/README.md](reference/README.md).

---

## Licence

[MIT](LICENSE) for the code. The flight data is not mine to license and carries its own terms —
attribution for adsb.lol's ODbL data, and the photographer credit for every photograph. Those are
set out in [NOTICE.md](NOTICE.md), along with how this app satisfies them.

Security reports: [SECURITY.md](SECURITY.md).
