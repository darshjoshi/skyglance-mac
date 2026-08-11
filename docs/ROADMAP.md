# Roadmap and design notes

Everything below was checked by running it, not from memory. Measurements were taken over a dense
metropolitan area unless stated otherwise; numbers will differ elsewhere, and the sections that
explain *why* a threshold was chosen matter more than the threshold itself.

---

## What exists right now

| Artifact | What it is | State |
|---|---|---|
| [RESEARCH.md](./RESEARCH.md) | Full landscape: FR24, FlightAware, OpenSky, community feeds, pricing, licensing | Done |
| [COVERAGE-AND-COST.md](./COVERAGE-AND-COST.md) | Measured coverage by source and region + every source's real cost | Done |
| [FREE-STACK.md](./FREE-STACK.md) | The 8-service free stack, architecture, reliability testing | Done |
| [OVERHEAD-DETECTION.md](./OVERHEAD-DETECTION.md) | Product requirements + the measured prediction limit | Done |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Mac architecture, WidgetKit constraints | Done |
| [reference/server.mjs](../reference/server.mjs) | Node reference backend: merge, breakers, SSE, enrichment | Working |
| [reference/overhead.mjs](../reference/overhead.mjs) | Node geometry engine + CLI | Working |
| [app/](../app) | **SkyGlance** — native macOS menu bar app | **Working** |

### The Mac app, concretely

```
app/Sources/OverheadKit/    Geometry · FeedClient (3-source merge, breaker) · SkyState
                            Interest (arc, scoring, alert budget, alert wording)
                            Weather (Open-Meteo) · Enrichment (route/operator/photo)
app/Sources/SkyGlance/      SwiftUI MenuBarExtra(.window) panel:
                            SkyModel (polling, scoring, alerts) · SkyDomeView (Canvas)
                            PanelView (headline, capped list, footer)
                            `--render <path>` draws the panel offscreen to a PNG
app/Sources/skyprobe/       threshold-tuning CLI: what would alert, and why
app/Tests/                  85 tests, all passing, no network
app/build-app.sh            wraps into a real .app (Developer ID signed, notarised)
```

Live output from the running app:

```
NEAREST
   N31754    P28A   2.2 km   9° up  SSE
   N4846     B06    3.6 km   5° up  ESE
   DAL2310   BCS3   4.8 km  39° up  SE
263 aircraft · adsb.fi, adsb.lol, airplanes.live
11% cloud · 51 km · clear
alerts sent today: 0/8
```

---

## Verified vs. not verified

**Verified by running it:**
- Free stack returns live data from all three feeds, merged by ICAO hex
- Merge adds ~15% more aircraft than the best single source (184 vs 162 London; 682 vs 588 NYC)
- Geometry correct — known-answer tests (45°, 90°, CPA timing, descent, compass)
- Enrichment: hex → aircraft, callsign → route with airport coordinates, registration → photo
- Full outage handling: 503 + explicit error, circuit breaker cuts a repeat call from 5s to 0.9ms
- Concurrency: 8 simultaneous requests share one upstream fetch
- Mac app runs as a menu bar agent, no Dock icon, live at 3s
- **22 hours continuous uptime, 29 MB memory, ~26,500 poll cycles, no crash and no feed blocking**

- **Notifications deliver.** Proven: `authorization=1 alertSetting=2 addError=none delivered=2`.
  One of those was a genuine engine-generated alert for AAL1936, a 737-800 on Newark final.
- **Interest engine**: visible-arc filter, category scoring, per-category budgets, weather gate.

**Not verified — do not assume these work:**
- **The alert *rate* is right.** Thresholds are evidence-informed but not evidence-proven; 3-minute
  samples are far too noisy to tune on. Needs a full day of real running.
- **The widget** — not built at all.
- **The sky dome** — not built at all.

---

## Design notes: seventeen bugs, mostly one bug

Worth listing in full, because they are the same class almost every time — **a failure and a normal
state rendering identically**. If you take one thing from this repository, take that: the hard part
of a live data product is not fetching the data, it is making "broken" look different from "quiet".

1. `/health` reported `"ok"` during a total outage (an under-sampled source held the light green)
2. A total outage returned `count: 0` — indistinguishable from "no aircraft here"
3. **5 of 6 concurrent requests returned an empty map** — each fired its own fetch and got rate-limited
4. Menu bar `✈ —` meant both "quiet sky" and "everything failed"
5. Same aircraft listed twice (overhead *and* nearest)
6. "in 15s  0° up" leaked into the NEAREST list — read as an imminent flyover when it was landing
7. **Visible-arc test inverted** — `180 - delta` instead of `delta`, so an east-facing profile
   admitted only western traffic. Caught by unit tests, then seen again in a stale release binary
   reporting westbound Newark departures as visible.
8. **Dedup ran before the emergency bypass** — an aircraft that had already alerted routinely could
   never alert again if it then squawked 7700. Dedup is now keyed by aircraft *and* category.
9. **A single global alert budget is spent first-come** — a busy morning of routine arrivals would
   consume the day and silently drop a 747 at noon. Now per-category lanes.
10. **The menu bar headline ignored the visible arc** — it was pointing WNW at a 737 behind the
    building. The arc was only ever applied to notifications.
11. **Background polling stopped entirely** after the SwiftUI rewrite: `.menuBarExtraStyle(.window)`
    only instantiates the content view when the panel opens, so `.task { start() }` never ran.
    Polling now belongs to the model's lifetime.
12. **"Demote" had silently become "hide"** — sorting visible-first *and* capping at 8 pushed
    out-of-arc aircraft past the cut, and made a list labelled "Nearest" show a 20 km aircraft while
    dropping one at 3 km. Ordering is now natural; visibility is purely a styling concern.
13. Headline and rows reflowed mid-glance, resizing the panel every few seconds. Both pinned to one line.
14. **A rare aircraft was silently lost to the weather gate** — the footer read `held: B744: dark`.
    Only emergencies bypassed weather, so a 747-400 overhead at night was suppressed. Rare and
    military now always alert; the *wording* changes instead ("passed overhead · too dark to see").
15. **The dome projected onto a part of the sky that is always empty.** Elevation mapped linearly to
    radius, so the 0–10° band — where *42 of 42* measured aircraft sat — got the outer 11% of the
    radius, 21% of the disc area. Every aircraft piled onto the rim and 79% of the pixels were
    permanently blank. The projection is now biased toward the horizon (`SkyProjection`, exponent
    0.35): 0–10° takes the outer 46% of the radius.
16. **A selected aircraft vanished mid-read.** `selected` was resolved against the eight-row list, so
    a closer aircraft appearing would push your selection out and close the detail card underneath
    you. It now resolves against the full dome contents.
17. **Trails drawn from dead reckoning would have been confidently wrong.** A 60 s synthetic tail
    measured 1.5–28 pt depending on geometry — the short ones invisible — and stretching the window
    to fix that pushed it past the 90 s straight-line window, next to three airports where aircraft
    turn constantly. Trails are now recorded, one sample per poll, drawn to a length target.

---

## Scope of improvements

### Blocking
- [ ] **A day of real running.** The only way to know whether the alert cadence feels right.

### High value, small effort
- [x] **Launch at login** via `SMAppService` — registered and verified (`status == .enabled`).
- [x] **Visible arc set to east ±110°** — includes north and south along the Hudson, where the
      helicopter corridor runs. Excludes only the western half behind the building.
- [ ] **Alert history in the menu** — what fired today and what was suppressed and why. Without it,
      tuning is guesswork. This is the next thing that makes a day of data actionable.
- [ ] **Decide whether NEAREST should respect the arc.** It currently lists everything nearby,
      including aircraft behind you; only alerting is arc-filtered. Defensible either way.

### The next real feature
- [x] **Sky dome view** — built, then rebuilt for legibility. Centre is straight up, rim is the
      horizon, visible arc shaded, aircraft coloured by class and sized by physical size.
      Elevation is now horizon-biased (see bug 15), aircraft are heading-rotated glyphs with
      recorded trails, and the notable few carry callsign labels. Live at display rate via
      `TimelineView(.animation)`, with fades as aircraft enter and leave range.
- [ ] **Map view** as the secondary toggle — MapKit, much less work.
- [x] **Selection detail** — tapping a row swaps the list for a card with operator, route, photo
      and a track link. Slides in and out rather than cutting.
      Route, operator and photo are already available from `server.mjs`'s enrichment path.

### Then
- [x] **Depth on tap** — selecting an aircraft shows operator, route, photo and attribution,
      backed by adsbdb → hexdb → planespotters with permanent on-disk caching (misses included).
      Measured hit rates over live traffic: route 12/14, aircraft 11/14, photo 12/14.
- [ ] **Night posture.** Still unfixed and now the most visible flaw: the panel says "Nothing worth
      looking at" and then lists seven aircraft you cannot see. Half the app's life is dark or
      overcast and the UI does not change posture.
- [ ] **Widget.** Needs an App Group entitlement + Team ID. Remember it can never be live — minutes,
      not seconds — so it's the ambient surface, not the alerting one.
- [ ] **Logbook** (SwiftData): every aircraft ever seen, first-sightings, personal records. This is
      the retention mechanic; without it the app is boring by day 3.
- [ ] **Trails on the dome for out-of-arc aircraft**, currently drawn only for what you can see.

### Bigger bets
- [ ] **A local receiver** (~$30–80). Complete coverage of one patch of sky, ~1s latency, no rate
      limit, and it raises FlightAware's free AeroAPI allowance from $5 to $20/month.
- [ ] **Schedules** via AeroDataBox (~$1–15/mo) — adds "is it late / which gate", which free ADS-B
      fundamentally cannot provide.

### Known technical debt
- `reference/server.mjs` fetches on request rather than polling in the background — fine for a
  prototype, wrong for production. (The Mac app doesn't have this problem; it polls continuously.)
- Enrichment cache is a JSON file; should be SQLite before it grows.

---

## What a busy sky looks like

Measured over a dense metropolitan area: **285 aircraft within 60 nm**. Within 40 nm, **57 were below
2,000 ft**, 85 between 2,000 and 10,000 ft, and only 8 above 25,000 ft. Twelve helicopters were
airborne along a single river corridor. The most common types were `C172` and `P28A` — light
aircraft, not airliners.

**This changed the design.** The interesting traffic near a city is low, not high. A 737 at 1,200 ft
on final sits at 2° elevation and would be thrown away by a naive "is it overhead" rule, yet it is
the most spectacular thing in the sky. Scoring is therefore driven by size and proximity, not by
elevation angle — and the sky dome's radial scale is biased toward the horizon for the same reason.

Point [`skyprobe`](../app/Sources/skyprobe) at your own coordinates to see what your sky looks like
before tuning anything.

## Running it

```bash
cd app
./build-app.sh && open build/SkyGlance.app          # the menu bar app
swift test                                          # 85 tests, offline

# What would have alerted over the last 30 minutes, and why
swift run -c release skyprobe 51.4700 -0.4543 30

# Optional Node reference implementation — the Mac app does not need it
node ../reference/overhead.mjs 51.4700 -0.4543      # CLI check of any location
node ../reference/server.mjs                        # web backend
```
