# Getting Maximum Flight Data — Measured Coverage & Real Costs

Companion to [RESEARCH.md](./RESEARCH.md). Everything here was measured with live API calls on
2026-07-25, not taken from vendor marketing. Test script: `scratchpad/coverage.py`.

---

## The question splits in two

"As much data as possible" is really two separate problems with different costs and different ceilings:

1. **Coverage** — how many aircraft are visible, and where? (limited by *physics and geography*)
2. **Depth** — how much is knowable about each one? (limited by *databases*, and mostly free)

Depth is the cheap win: you can go from "a hex code and a dot" to "United Express ERJ-175, LHR→JFK,
with a photo and the operator's name" for **$0/month**. Coverage is where money actually goes, and
where free sources hit a hard wall.

---

## Part 1 — Coverage: how much does stacking sources actually buy you?

The same circle was queried on all four free sources simultaneously, comparing the sets of unique
aircraft (by ICAO hex, position-filtered to the actual circle).

### Measured results

| Region | adsb.lol | airplanes.live | adsb.fi | OpenSky | **Union** | Gain vs. best single |
|---|---|---|---|---|---|---|
| London, 150nm | 156 | 157 | 162 | 146 | **184** | **+13.6%** |
| New York, 150nm | 581 | 572 | 588 | 571 | **682** | **+16.0%** |
| Mumbai, 150nm | 27 | 13 | 0* | 21 | **29** | +7.4% |
| Mid-North-Atlantic, 250nm | 0 | 12 | 0 | 0 | **12** | +0% |
| Central Africa, 250nm | 0 | 0 | 0 | 0 | **0** | — |

\* adsb.fi returned empty/errored on two of five probes — it was the flakiest of the three.

### What this tells you

**Stacking free sources is worth doing, but it's a ~15% gain, not a 4× gain.** The three community
feeds overlap ~90% because they're fed by overlapping volunteer receivers. Adding a second community
feed bought 2–10 extra aircraft. Adding **OpenSky** was consistently the biggest single win (+16
unique over London, +62 over New York) because it has a genuinely different feeder network plus
some institutional receivers.

**The real gap is geographic, not source-diversity.** No amount of stacking free sources fixes
central Africa returned **zero aircraft across all four sources, twice**, over a 250nm circle. There
is real traffic there; there are simply no volunteer receivers. Same story mid-Atlantic: 12 aircraft
where the North Atlantic Track system typically has 50–150 airborne. And Mumbai — one of the world's
busiest airports — returned 29 aircraft where FR24 would show well over 100.

**So the honest ceiling on free data:**
- Dense Europe / US / East Asia: **90–95% of what FR24 shows.** Genuinely competitive.
- India, Latin America, Southeast Asia: **maybe 25–50%.** Noticeably thin.
- Oceans, Africa, central Asia, polar: **0–20%.** Effectively blind.

That gap is only closable with satellite ADS-B and ATC radar feeds, which are FR24's and
FlightAware's actual product and are not sold at indie scale.

### How much of the world can you sweep, for free?

A 250nm-radius query covers ~673,000 km². At airplanes.live's documented **1 request/second**:

| Target | Circles needed | Full sweep time (1 feed) | With 3 feeds in parallel |
|---|---|---|---|
| Air-traffic-relevant regions | ~150 | **2.5 min** | ~50 s |
| All land | ~295 | ~5 min | ~1.7 min |
| Entire planet | ~1,010 | ~17 min | ~6 min |

**You can maintain a live picture of every trafficked region on Earth, refreshed every ~2–3 minutes,
for $0.** For a single region you care about, you get a fresh view every second. That's a far better
position than the pricing pages suggest.

---

## Part 2 — Depth: free enrichment (all verified working today)

This is where you get disproportionate value. Every one of these returned real data on a live call:

| Need | Source | Cost | Verified result |
|---|---|---|---|
| hex → aircraft type, reg, owner | **adsbdb.com** `/v0/aircraft/{hex}` | **$0** | `A8FFC4` → Bell 206B Jet Ranger, N67919, Private |
| hex → aircraft (alt) | **hexdb.io** `/api/v1/aircraft/{hex}` | **$0** | Same, leaner payload |
| callsign → full route | **adsbdb.com** `/v0/callsign/{cs}` | **$0** | `BAW117` → British Airways "SPEEDBIRD", EGLL London Heathrow → JFK, **with airport coordinates** |
| callsign → route (alt) | **hexdb.io** `/api/v1/route/icao/{cs}` | **$0** | `BAW117` → `EGLL-KJFK` |
| registration → photo | **planespotters.net** `/pub/photos/reg/{reg}` | **$0** | `N764YX` → photo URL, thumbnail, photographer credit |
| Airport database | **OurAirports** `airports.csv` | **$0** | 12.7 MB, public domain, every airport on Earth |
| Bulk aircraft database | **OpenSky S3** `aircraft-database-complete-*.csv` | **$0** | ~57 MB CSV, monthly snapshots |

**Gotcha:** planespotters rejects generic user agents — it returns an error telling you to send a
descriptive `User-Agent` with a contact URL. With a proper one it works fine. Attribution
(photographer credit) is expected.

**What free enrichment does NOT give you:** scheduled times, gates, terminals, delay status, or
baggage belts. That is airline-sourced data, and it is paid, full stop. Cheapest real option is
AeroDataBox from ~$0.99/mo.

---

## Part 3 — Cost of every source

### Free (verified)

| Source | Cost | Gives you | Limit / catch |
|---|---|---|---|
| adsb.lol | **$0** | Live positions, **ODbL — commercial OK** | Dynamic rate limit, 250nm max radius, no SLA |
| airplanes.live | **$0** | Live positions + `desc`/`ownOp`/`year` | 1 req/s, non-commercial, no SLA |
| adsb.fi | **$0** | Live positions + enrichment fields | Flakiest of the three in testing |
| OpenSky | **$0** | **Global snapshot in one call** (10,929 aircraft, 0.97s) | 4,000 credits/day registered; non-commercial **and** written licence needed for any live product |
| adsbdb.com | **$0** | Routes + aircraft metadata | Be polite; community-run |
| hexdb.io | **$0** | Routes + aircraft metadata | Same |
| planespotters.net | **$0** | Aircraft photos | Descriptive UA required, attribution expected |
| OurAirports | **$0** | Airport database | Bulk CSV, refresh occasionally |

### Hardware (one-time)

| Item | Cost | Gives you |
|---|---|---|
| RTL-SDR dongle or FlightAware ProStick Plus | **$20–30** | Your own 1090 MHz receiver |
| Raspberry Pi (any) + SD card | **$0–50** (reuse one) | The host |
| Decent 1090 MHz antenna | **$0–30** (DIY coat hanger works) | 100–200 km → 300–400 km range |
| **Total** | **~$30–80 once** | **Unlimited, ~1s latency, zero rate limit, zero ToS** |

Plus, for feeding it onward: FlightAware gives **$20/mo of free AeroAPI credit** (vs $5 normally),
OpenSky doubles you to 8,000 credits/day, FR24 gives a free Business account (still no API).

### Paid

| Source | Entry cost | Gives you | Billing model |
|---|---|---|---|
| **ADS-B Exchange** | **$10/mo** | 10,000 req/mo, **unfiltered** (shows LADD/PIA aircraft others hide) | Flat, via RapidAPI |
| **AeroDataBox** | **$0.99/mo** (600 calls) → $150/mo (300k) | Schedules, status, gates, aircraft metadata | Per call |
| **FlightAware AeroAPI** | **$5/mo free** ($20 if you feed) → **$200/mo min** for Standard | Schedules, gates, actual-vs-scheduled, US radar coverage | Per "result set" (15 records) |
| **aviationstack** | Free (100 calls, personal use only) → **$49.99/mo** | Schedules + status | Per call |
| **Flightradar24** | **$9** / **$90** / **$900** per month | Best global coverage, ocean + radar, history to 2016 | **Per aircraft returned** — 6 credits each |
| Cirium / OAG | Enterprise quote | Authoritative airline schedules | Contract |

**The FR24 trap, restated with the measured number:** a New York 150nm query returned 682 aircraft.
On FR24's live-positions-light endpoint that's 682 × 6 = 4,092 credits ≈ **$1.23 for one refresh**.
The $9 Explorer plan's entire monthly allowance buys ~14 of those, and caps responses at 20 results
anyway. FR24's API is for *looking up one flight*, and it's good at that.

---

## Part 4 — Recommended stacks by budget

### $0/month — and it's genuinely strong
```
Positions:   adsb.lol (primary) + airplanes.live + adsb.fi  → union, ~15% more than any one alone
             + OpenSky registered account for the global view
Enrichment:  adsbdb.com (route + aircraft) → hexdb.io (fallback) → planespotters (photos)
Static:      OurAirports CSV + OpenSky aircraft DB, cached locally
```
**Gets you:** ~90–95% coverage in Europe/US/East Asia, full aircraft identity, routes, photos.
**Missing:** oceans, Africa, schedules, gates, delays.

### +$30–80 once — add your own receiver
Unlimited zero-latency data for your own ~300 km, no rate limit, no terms. Unlocks the FlightAware
**$20/mo free credit**, which is effectively a permanent free schedules tier. Best value in the
whole document.

### ~$10–25/month — fill the specific holes
- **$10** ADS-B Exchange if you want unfiltered/blocked aircraft.
- **$1–15** AeroDataBox for schedules and gates — the single biggest *product* upgrade, because it
  adds a whole dimension free ADS-B cannot: "is it late, and which gate."

### ~$90–200/month — buy real coverage
FR24 **Essential ($90)** is the cheapest legitimate access to ocean and radar-derived positions,
plus 2 years of history and 300-result responses. Use it for tap-through detail, never for the map.
Or AeroAPI **Standard ($200 min)** if schedules and US radar matter more than global positions.

### $900+/month — Advanced tier
Only if the product itself is the completeness. At which point, check the revenue model first.

---

## Part 5 — Engineering rules that follow

1. **Query all sources in parallel, merge by ICAO hex.** That's the +16%. Prefer the record with the
   lowest `seen_pos` (freshest). The test script does exactly this in ~1 second wall-clock.
2. **Cache enrichment aggressively and permanently.** hex → aircraft type basically never changes.
   Callsign → route changes rarely. One lookup per aircraft, ever — not per position update.
   This turns thousands of enrichment calls into dozens.
3. **Tile the world at 1 req/s if you want global.** ~150 circles covers everywhere with traffic,
   refreshed every 2.5 minutes. Rotate hot regions more often than empty ones.
4. **Treat coverage gaps as a UI problem, not a data problem.** Over Africa or the Atlantic you *will*
   lose aircraft. Saying "out of receiver coverage" honestly is better UX than a fake interpolated
   position — and it's a thing FR24 can't say because it would undercut their product.
5. **Don't pay per-aircraft for anything you render.** Paid calls fire on user intent (a tap), never
   on map refresh. This keeps cost proportional to engagement instead of to air traffic.

---

## Appendix — reproducing this

```bash
python3 scratchpad/coverage.py     # coverage comparison across all four free sources
```
Note: system Python on macOS lacks CA certs for `urllib`, so the script shells out to `curl`.

Raw enrichment checks:
```bash
curl "https://api.adsbdb.com/v0/callsign/BAW117"
curl "https://api.adsbdb.com/v0/aircraft/A8FFC4"
curl "https://hexdb.io/api/v1/route/icao/BAW117"
curl -A "your-app/1.0 (+contact)" "https://api.planespotters.net/pub/photos/reg/N764YX"
```
