# Flight Tracking: Data Sources, APIs & What It Costs

Research compiled 2026-07-25. All pricing and limits verified against live vendor pages; free APIs
tested with real requests (results in [Appendix A](#appendix-a-live-test-results)).

---

## TL;DR

1. **A consumer Flightradar24 subscription grants zero API access.** FR24 states plainly that the
   website and the API are "separate standalone products that require separate subscriptions."
   Feeding them data doesn't unlock it either.
2. **The FR24 API is priced per aircraft returned, which makes it ruinous for a live map.**
   One refresh of a busy 250nm circle (≈993 aircraft) costs ~$1.79. A map refreshing every 5s costs
   **~$1,280/hour**. It's built for looking up *one flight*, not painting *all flights*.
3. **The free community ADS-B feeds (adsb.lol, airplanes.live, adsb.fi) are the right backbone for a
   live map.** No key, no cost, ~1s response, and all three speak the identical JSON schema so they
   drop in as failovers for each other.
4. **No ADS-B source gives you schedules.** FR24's API explicitly has no scheduled-flight data. If
   you want a departure board ("BA117 scheduled 18:40, gate B32"), that's a separate, second API.
5. **Highest-leverage move available:** put a $30 RTL-SDR receiver on a window and feed it.
   FlightAware gives feeders $20/mo of free AeroAPI credit, OpenSky doubles the quota, FR24 gives a
   free Business account.

---

## 1. How flight tracking actually works

Everything downstream is a consequence of these five data sources. Knowing which source a provider
has is the *only* thing that explains their price.

| Source | What it is | Who has it |
|---|---|---|
| **ADS-B (1090 MHz)** | Aircraft self-reports GPS position ~1×/sec. Unencrypted, anyone with a $30 dongle can receive it. | Everyone |
| **UAT (978 MHz)** | US-only, general aviation below 18,000 ft. | US-focused providers |
| **MLAT** | Older Mode-S aircraft don't broadcast position. Four+ receivers time-difference the signal to triangulate it (~10–20 m accuracy). Needs receiver density. | FR24, FlightAware, ADSBx, community feeds (partial) |
| **Radar / ATC feeds** | FAA and other ATC data covering aircraft with no ADS-B at all, plus oceanic. | FR24, FlightAware (commercial agreements) |
| **Satellite ADS-B** | Aireon/Spire receivers in orbit. The only way to see mid-ocean and polar traffic. | FR24, FlightAware, enterprise only |

**This is the whole story on pricing.** ADS-B is free physics — that's why adsb.lol can give it
away. Radar feeds and satellite ADS-B are contractual and expensive — that's why FR24 and
FlightAware charge, and why their terms forbid you redistributing it.

**Practical consequence:** free community feeds have *excellent* coverage over populated land
(Europe, US, East Asia) and *poor to zero* coverage over oceans, Africa, central Asia, and at low
altitude away from cities. FR24 fills those gaps. For an app about "planes over one city," free feeds
are equal or better. If it's "track this transatlantic flight door to door," they're not.

**Two more things that bite:**
- **Blocked aircraft.** LADD (FAA's Limiting Aircraft Data Displayed) and PIA (Privacy ICAO Address)
  hide private jets on most commercial platforms. ADS-B Exchange built its reputation on *not*
  filtering. Community feeds tag them (`/ladd`, `/pia`) but generally show them.
- **"Estimated" positions.** When FR24 loses signal it interpolates along the expected route and
  shows a dashed line. That's a product decision you'll have to make yourself with raw ADS-B — a
  plane will just vanish over the Atlantic.

---

## 2. Flightradar24 — the consumer product vs. the API

### The consumer subscription
Silver / Gold / Business buy the *app and website*: 365 days of flight history (Gold), 3D view,
weather layers, aeronautical charts, more aircraft detail. It is a **viewing product**. There is no
data export, no key, no programmatic access.

From the FR24 API FAQ, verbatim on the two points that matter:

> "Yes, the Flightradar24 website and the API are separate standalone products that require separate
> subscriptions."

> "Currently, we do not offer any free-of-charge API access to receiver hosts."

So: no API from a consumer subscription, and no API even for people who feed them data.

### The FR24 commercial API (fr24api.flightradar24.com)

| Plan | Price | Credits/mo (base) | Credits/mo (promo*) | Max results per response | Rate limit | History |
|---|---|---|---|---|---|---|
| Explorer | $9 | 30,000 | 60,000 | **20** | 10 req/min | 30 days |
| Essential | $90 | 333,000 | 666,000 | 300 | 30 req/min | 2 years |
| Advanced | $900 | 4,050,000 | 8,100,000 | Unlimited | 90 req/min† | All available |

\* FR24 is running a "Double Credits Deal" through 2026-12-31 — buy/renew before then and every
billing cycle starting on or before that date gets doubled credits.
† The docs say 90 queries/min for Advanced; the pricing page says 200. Confirm before you commit.

**Credit costs — this is the part that matters:**

| Endpoint | Charged | Credits |
|---|---|---|
| Live flight positions — **light** | per returned flight | **6** |
| Live flight positions — full | per returned flight | **8** |
| Flight summary — light | per returned live flight | 1 |
| Flight summary — full | per returned live flight | 2 |
| Flight summary — full (historic >30d) | per flight | 6 |
| Flight tracks (full flown profile) | per flight | **40** |
| Airports light / Airlines light | per query | 1 |
| Airports full | per query | 50 |
| Empty response | flat | 1 |

Credits cost ~$0.0003 each at Explorer, dropping to ~$0.000248 on bulk top-ups.

**The math that kills it for a map.** A measured 993 aircraft sat in a 250nm circle around New York:

| Scenario | Credits | Cost |
|---|---|---|
| One refresh of that area (light) | 5,958 | **$1.79** |
| Refreshing every 5s, for 1 hour, 1 user | 4,289,760 | **$1,287** |
| What Explorer's whole month buys you | 60,000 | **~10 refreshes** |

Explorer also caps responses at **20 results** — you physically cannot render a map on it.

**Verdict:** the FR24 API is excellent and fairly priced *for what it's designed for* — asking about
one flight, one registration, one route, with world-class coverage behind it. It is the wrong tool
for a live map, by roughly three orders of magnitude.

**Two more restrictions to design around:**
- **30-day storage rule:** "All data accumulated from the FR24 API should not be stored for more
  than 30 days from the date it was first received." No permanent flight history database.
- **No schedules.** The API only knows about aircraft *currently transmitting*. Scheduled departures
  you see on the website are not exposed. FR24 calls this one of their most-requested missing features.
- Live positions update ~every 3 seconds per aircraft; response latency <1s for typical queries.

**Sandbox:** free, no credits consumed, static responses matching the production schema. You can
build and test the whole integration before paying anything. Prepend `sandbox` to the endpoint.

### Scraping FR24 — don't
The unofficial `FlightRadarAPI` Python package and various scrapers work by hitting FR24's internal
endpoints. This violates their ToS; they explicitly reserve the right to terminate for it, and their
objection is contractual (redistributing radar/satellite data they license from partners), not
merely territorial. Fine for a throwaway personal script. Not something to build a product on.

---

## 3. The free / open sources

### Community ADS-B feeds — adsb.lol, airplanes.live, adsb.fi
These sprang up after ADS-B Exchange was acquired by JETNET in 2023 and much of the volunteer
community left. All three are volunteer-fed, all three run the same `readsb`/`tar1090` stack, and —
**verified** — return byte-for-byte compatible JSON. Swapping between them is a base-URL change.

| | adsb.lol | airplanes.live | adsb.fi |
|---|---|---|---|
| Base URL | `api.adsb.lol/v2` | `api.airplanes.live/v2` | `opendata.adsb.fi/api/v2` |
| API key | None | None | None |
| Rate limit | Dynamic, load-based | **1 req/sec** | Unspecified |
| License | **ODbL 1.0** (commercial OK w/ attribution + share-alike) | Non-commercial | Open |
| SLA | None | Explicitly none | None |
| Enrichment | Lean payload | `desc`, `ownOp`, `year` included | `desc`, `ownOp`, `year` included |

**Endpoints** (same across all three): `/point/{lat}/{lon}/{radius_nm}` (max 250nm), `/hex/{icao}`,
`/callsign/{cs}`, `/reg/{reg}`, `/type/{icao_type}`, `/squawk/{code}`, `/mil`, `/ladd`, `/pia`.

adsb.lol's **ODbL license is the standout** — it's the only free source whose terms don't block
commercial use. The tradeoff is ODbL's share-alike clause: if you publish a derived *database*, it
has to be open too. Using the data in an app is fine; selling a proprietary dataset built from it
isn't.

**No global endpoint.** Max radius is 250nm, deliberately, to stop bulk harvesting. Worldwide
coverage means tiling many requests — respect that, or use OpenSky for the global view.

### OpenSky Network
Academic/research network, and the only free source with a true global snapshot in one call.

- **Auth:** OAuth2 client credentials since 2026-03-18 (username/password is dead). Tokens last 30 min.
- **Quotas:** anonymous 400 credits/day · registered 4,000 · **feeder (≥30% uptime) 8,000** · licensed 14,400/hour
- **Credit cost of `/states/all`:** ≤25 sq° = 1 · 25–100 sq° = 2 · 100–400 sq° = 3 · global = 4
- **So:** registered = ~1,000 global snapshots/day (one per 86s), or ~4,000 small-bbox queries/day (one per 21s)
- **History:** 1 hour back, 5s resolution. `/flights/*` and `/tracks` go further but cost 30–960 credits.

**The catch, and it's a big one.** OpenSky's licence grants use "solely for the purpose of non-profit
research and non-profit education," *and* separately requires a written licence for "operational use
of the REST API in any live product, service, or automated system" — regardless of whether you're
non-profit. A public web app is operational use. Great for prototyping and personal projects;
email them before it's a product.

---

## 4. The commercial options

| Provider | Entry price | Model | Best at | Watch out for |
|---|---|---|---|---|
| **Flightradar24 API** | $9/mo (Explorer) | Per aircraft returned | Best global coverage; per-flight lookups; historic back to **2016-05-11** | Unusable cost for maps; 30-day storage cap; no schedules |
| **FlightAware AeroAPI v4** | **$5/mo free usage** ($20 for feeders) | Per "result set" (15 records) | Flight *status*: schedules, gates, actual vs. scheduled times, US radar coverage | Standard tier jumps to **$200/mo minimum** |
| **ADS-B Exchange** | $10/mo via RapidAPI | 10,000 requests/mo | **Unfiltered** — shows LADD/PIA aircraft others hide | Community tier is non-commercial; enterprise is quote-only |
| **AeroDataBox** | $0.99/mo (600 calls) → $150/mo (300k) | Per call | Cheapest schedules/status/aircraft metadata. Best value for prototyping | Aggregator, not a primary sensor network |
| **aviationstack** | Free (100 calls, **personal use only**) → $49.99/mo | Per call | Simple schedules + status | Free tier bans commercial use; paid entry is steep for what it is |
| **Cirium / OAG** | Enterprise quote | Contract | Authoritative airline schedules, the data airlines themselves buy | Sales cycle, five figures |

**The AeroAPI feeder deal is worth flagging:** run a receiver and the free monthly allowance goes
from $5 to $20, plus geospatial access within 250nm of the station. That's a real, permanent free
tier for schedules + status, which is exactly the thing free ADS-B can't give you.

---

## 5. Run your own receiver

Best value in this entire document.

**Hardware:** ~$30–50 total. RTL-SDR dongle (~$30) or FlightAware ProStick Plus ($20–30, has a
1090 MHz bandpass filter that meaningfully cuts cell-tower interference), plus any Raspberry Pi.

**Software:** `readsb` (the maintained fork of dump1090) + `tar1090` for a local web map. Then layer
feeder clients on top — `piaware` (FlightAware), `fr24feed` (FR24), `rbfeeder` (RadarBox) — all
simultaneously, from one dongle.

**Range:** 100–200 km on the bundled dipole; 300–400 km with a proper 1090 MHz antenna with clear
sky view (a quarter-wave ground plane you can build from a coat hanger gets you most of the way).

**What you get back:**

| Feed to | You receive |
|---|---|
| FlightAware | Free Enterprise account + **$20/mo AeroAPI credit** + 250nm geospatial access |
| Flightradar24 | Free Business subscription (still **no** API access) |
| OpenSky | 8,000 credits/day (2× the registered quota) |
| Yourself | A raw, unlimited, zero-latency, zero-ToS local feed via `readsb`'s JSON output |

That last row is the real prize: your own receiver has no rate limit, no licence, and ~1-second
latency because there's no network hop. For anything centred on where you actually live, it beats
every paid API.

---

## 6. If you're building the app

### Recommended shape

```
readsb (own receiver, optional)  ─┐
adsb.lol      (primary)          ─┼─→  poller  →  in-memory/Redis state  →  WS/SSE  →  browser
airplanes.live / adsb.fi (fallback)┘      1 req/s        (world snapshot)    viewport-filtered
                                                                ↓
AeroDataBox / AeroAPI  ──→  on-demand enrichment (schedule, gate, status) — cached, per-flight only
```

**Rules that follow from the research:**

1. **Never call the ADS-B API from the browser.** One shared server poller at ~1 req/s serves
   unlimited users. Per-user polling burns the rate limit at user #2 and is the fastest way to get
   a community feed to block you.
2. **Send each client only its viewport.** 993 aircraft is 492 KB of raw JSON. Strip to the ~10
   fields you render and it's ~60 KB; send deltas after the first frame and it's a few KB.
3. **Dead-reckon on the client.** You get a position ~every 1–5s. Extrapolate from `gs` (ground
   speed) + `track` at 60fps so aircraft glide instead of teleporting. This single detail is most of
   what makes FR24 *feel* good, and it costs nothing.
4. **Failover across the three community feeds.** Identical schemas, no SLA on any of them. A 3-way
   round-robin with health checks turns three best-effort services into one reliable one.
5. **Budget FR24/AeroAPI for the detail panel, not the map.** Map = free ADS-B. User taps a plane =
   one paid call, cached. That keeps paid usage proportional to *engagement*, not to traffic volume.

### Field gotchas (from real payloads)
- `alt_baro` is **`"ground"` (a string)** when the aircraft is on the ground — it will crash naive
  numeric parsing. This is the single most common bug in ADS-B apps.
- `flight` (callsign) is space-padded to 8 chars — `"RPA3443 "`. Always trim.
- `hex` = ICAO 24-bit address, the only stable aircraft identity. `r` = registration, `t` = ICAO type code.
- `mlat` and `tisb` are arrays listing which fields came from those (less accurate) sources.
- `seen_pos` = seconds since last position. Anything over ~60 should be faded or dropped.
- Aircraft with no `lat`/`lon` appear in results (signal received, position not yet decoded) — filter them.
- The 250nm query returned 993 aircraft against a documented 1,000-result cap. Assume dense regions
  are truncated and tile your queries.

### Rendering
MapLibre GL JS (open source, no Mapbox bill) as the base map. Under ~2,000 aircraft a plain symbol
layer over a GeoJSON source is fine and simplest. Above that, deck.gl's `IconLayer` on top of
MapLibre pushes into the tens of thousands. Don't reach for deck.gl until the simple version is
measurably too slow.

---

## 7. Straight answer to "what should I use?"

- **Live map of aircraft** → adsb.lol (ODbL, commercially usable) with airplanes.live + adsb.fi as
  failover. Free, tested, ~1s.
- **Global single-call snapshot / prototyping** → OpenSky registered account. Email them before it's public.
- **Schedules, gates, on-time status** → AeroDataBox (cheapest) or AeroAPI (better, free-ish if you feed).
- **Best-in-world per-flight detail and ocean coverage** → FR24 API Essential ($90). Only if the
  product genuinely needs it, and only for tap-through lookups.
- **One specific area, unlimited, no ToS** → a $30 receiver. Worth doing regardless.
- **A consumer FR24 subscription** → useful as a *user*, to sanity-check what your own app shows.
  Contributes nothing to the build.

---

## Appendix A: Live test results

All requests made 2026-07-25, from this machine, unauthenticated.

| Test | Result |
|---|---|
| `api.adsb.lol/v2/point/40.7/-74.0/250` | **993 aircraft**, 492 KB, **1.11 s** |
| `api.adsb.lol/v2/mil` (global military) | 126 aircraft, 46 KB, 1.16 s |
| `api.airplanes.live/v2/point/40.64/-73.78/25` | OK — includes `desc`, `ownOp`, `year` |
| `opendata.adsb.fi/api/v2/lat/40.64/lon/-73.78/dist/25` | OK — same schema, `now` timestamp at root |
| `opensky-network.org/api/states/all` (anonymous, global) | **10,929 aircraft**, 1.44 MB, **0.97 s** |
| `opensky-network.org/api/states/all` (NYC bbox, anonymous) | OK, no auth required |

Cross-checked: the same aircraft (`a8ffc4` / N67919, a Bell 206) appeared with identical position and
timestamp across adsb.lol, airplanes.live, and adsb.fi — confirming a shared upstream and
interchangeable schemas.

---

## Sources

- [Flightradar24 API — Subscriptions & credits](https://fr24api.flightradar24.com/subscriptions-and-credits)
- [Flightradar24 API — Credit Overview](https://fr24api.flightradar24.com/docs/credit-overview)
- [Flightradar24 API — Endpoints](https://fr24api.flightradar24.com/docs/endpoints/overview)
- [Flightradar24 API — FAQ](https://fr24api.flightradar24.com/docs/faq)
- [Flightradar24 — How it works](https://www.flightradar24.com/how-it-works) · [MLAT](https://www.flightradar24.com/how-it-works/mlat)
- [Flightradar24 — Subscription plans](https://www.flightradar24.com/premium) · [Terms of Service](https://www.flightradar24.com/terms-of-service)
- [OpenSky REST API docs](https://openskynetwork.github.io/opensky-api/rest.html) · [Terms of Use & Data License](https://opensky-network.org/about/terms-of-use)
- [airplanes.live REST API guide](https://airplanes.live/api-guide/)
- [adsb.lol API docs](https://www.adsb.lol/docs/open-data/api/) · [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/)
- [adsb.fi opendata](https://github.com/adsbfi/opendata)
- [ADS-B Exchange Developer Hub](https://www.adsbexchange.com/community/developer-hub/) · [Data Products](https://www.adsbexchange.com/data-products/)
- [FlightAware AeroAPI](https://www.flightaware.com/commercial/aeroapi/) · [v4](https://www.flightaware.com/commercial/aeroapi/v4/)
- [AeroDataBox pricing](https://aerodatabox.com/pricing/) · [aviationstack pricing](https://aviationstack.com/pricing)
- [MapLibre GL JS](https://maplibre.org/projects/gl-js/) · [deck.gl with MapLibre](https://deck.gl/docs/developer-guide/base-maps/using-with-maplibre)
