# The Free Stack — What It Is, How To Build On It, How Reliable It Actually Is

Companion to [RESEARCH.md](./RESEARCH.md) (landscape) and [COVERAGE-AND-COST.md](./COVERAGE-AND-COST.md)
(measured coverage). This document is about the *engineering*: a working backend, running, with
measured failure behaviour.

Reference implementation: [`server.mjs`](../reference/server.mjs) — one file, **zero dependencies**, Node 18+.

---

## 1. What "the free stack" actually is

It isn't one service. It's **eight free services in three layers**, and the whole trick is that no
single one of them is reliable enough to build on alone — but combined, they are.

### Layer 1 — Positions (where the aircraft are)

| Service | Role | Why it's in the stack |
|---|---|---|
| **adsb.lol** | Primary | Only free feed under **ODbL** — the one licence that permits commercial use |
| **airplanes.live** | Redundancy | Different feeder subset; caught aircraft the others missed over the Atlantic |
| **adsb.fi** | Redundancy | Third independent feeder subset |
| **OpenSky** | Coverage boost | Genuinely different network — contributed the most unique aircraft in testing |

All four speak effectively the same schema (OpenSky uses positional arrays; the other three are
byte-compatible `readsb` JSON). One adapter each, ~15 lines.

### Layer 2 — Identity (what each aircraft is)

| Service | Gives you |
|---|---|
| **adsbdb.com** | hex → registration, type, manufacturer, owner · callsign → full route with airport coordinates |
| **hexdb.io** | Same, as a fallback when adsbdb misses or is down |
| **planespotters.net** | registration → real photograph + photographer credit |

### Layer 3 — Static reference (downloaded once, cached forever)

| Source | Size | Use |
|---|---|---|
| **OurAirports** `airports.csv` | 12.7 MB | Every airport on Earth, public domain |
| **OpenSky aircraft DB** | ~57 MB | Bulk hex → aircraft, so you're not lookup-dependent |

**Total cost: $0/month.** No API keys anywhere in this stack.

---

## 2. The architecture, and why it's shaped this way

```
   ┌──────────────┐  ┌────────────────┐  ┌──────────┐  ┌─────────┐
   │  adsb.lol    │  │ airplanes.live │  │ adsb.fi  │  │ OpenSky │   Layer 1
   └──────┬───────┘  └───────┬────────┘  └────┬─────┘  └────┬────┘
          └──────────────────┴────────────────┴─────────────┘
                             │  parallel fetch, 5s timeout each
                    ┌────────▼─────────┐
                    │ circuit breakers │   3 strikes → 30s cooldown
                    └────────┬─────────┘
                    ┌────────▼─────────┐
                    │  merge by hex    │   freshest position wins,
                    │  + backfill      │   null fields filled from others
                    └────────┬─────────┘
                    ┌────────▼─────────┐
                    │ snapshot store   │   last-good, served if all sources die
                    └────────┬─────────┘
              ┌──────────────┴──────────────┐
        ┌─────▼──────┐              ┌───────▼────────┐
        │ /api/...   │              │    /stream     │  SSE, 2s
        └────────────┘              └────────────────┘
                    ┌──────────────────────────────────┐
                    │ enrichment (on demand, cached ∞) │   Layer 2
                    │ adsbdb → hexdb → planespotters   │
                    └──────────────────────────────────┘
```

**The four decisions that matter:**

1. **One server polls; every user reads from its snapshot.** The rate limits are ~1 req/sec *total*,
   not per user. Poll from the browser and you break at user #2. This single choice is the difference
   between a stack that serves 10,000 people and one that serves one.
2. **Merge, don't failover.** Failover would use one source and switch on failure. Merging queries
   all four every time and unions the results — you get the reliability *and* the ~16% extra coverage.
3. **Enrichment is cached forever, including misses.** Hex → aircraft type never changes. One lookup
   per aircraft for all time, not one per position update. Caching negative results matters just as
   much, or unknown aircraft get retried on every single frame.
4. **Stale data beats an error.** If everything upstream dies, serve the last good snapshot with
   `stale: true` and let the UI decide. A 40-second-old plane is more useful than a spinner.

---

## 3. What's built, and proof it runs

`server.mjs`, started with `node server.mjs`. All output below is from real runs.

### `GET /api/aircraft?lat=51.47&lon=-0.45&radius=150`
```
HTTP:200  time:0.478s  size:68,280 B
count: 192 | ageMs: 0 | degraded: false | stale: false
sources: [{"adsb.lol":145},{"airplanes.live":146},{"adsb.fi":147},{"opensky":160}]
aircraft seen by >1 source: 147 / 192
```
**192 merged from a best-single-source of 160** — the merge is doing real work. 68 KB for 192
aircraft, because the normalizer drops the ~20 ADS-B signal-quality fields you'll never render.

### `GET /api/aircraft/4ca2c9?callsign=EIN529`
```json
{
  "aircraft": { "registration": "EI-DEP", "type": "A320 214", "manufacturer": "Airbus",
                "owner": "Aer Lingus", "country": "Ireland", "source": "adsbdb" },
  "route":    { "airline": "Aer Lingus",
                "origin":      { "icao": "LFPG", "iata": "CDG", "name": "Charles de Gaulle International Airport" },
                "destination": { "icao": "EIDW", "iata": "DUB", "name": "Dublin Airport" } },
  "photo":    { "thumbnail": "https://t.plnspttrs.net/43495/1864265_b4e8176cfe_280.jpg",
                "photographer": "Marvin Knitl" }
}
```
A bare hex code became a fully-identified aircraft with route and photograph. **Cost: $0.**
Cold: ~1s across three services. Warm: **18 ms**.

### `GET /stream` (SSE)
```
data: {"count":101,"ageMs":0,"stale":false,"degraded":false ...
data: {"count":100,"ageMs":0,"stale":false,"degraded":false ...
data: {"count":101,"ageMs":0,"stale":false,"degraded":false ...
```

---

## 4. Reliability — measured, not assumed

### 4a. Sustained soak

Every source polled on a fixed interval for 10 minutes against London 150nm:

```
RELIABILITY REPORT — 67 rounds over 600s, London 150nm
======================================================================
source             uptime   p50 ms   p95 ms   max ms  avg ac  errors
adsb.lol           100.0%      774     1671     2110     139  -
airplanes.live     100.0%      374      543      652     141  -
adsb.fi            100.0%      404      506      654     141  -
opensky            100.0%      465      521     1080     154  -
----------------------------------------------------------------------
all 4 sources healthy : 100.0% of rounds
>=3 sources healthy   : 100.0% of rounds
>=1 source healthy    : 100.0% of rounds   <-- effective uptime with failover
```

**268 requests, zero failures.** Latency is good across the board — airplanes.live and adsb.fi are
the quickest (p95 ~0.5s), adsb.lol the slowest and most variable (p95 1.7s, max 2.1s).

Be careful how much you read into this: 10 minutes is a snapshot, not an SLA, and it says nothing
about behaviour during an outage, a traffic spike, or two years from now. What it does establish is
that on an ordinary day these services are *fast and stable*, not marginal.

### 4b. Fault injection — all four sources blackholed

Every upstream was repointed at an unroutable address, then the API was hit:

```
{"count":0,...,"degraded":true,"error":"all sources unavailable",...}  HTTP:503  t:5.014s
{"count":0,...,"error":"all sources unavailable",...}                  HTTP:503  t:5.004s
{"count":0,...,"error":"all sources unavailable",...}                  HTTP:503  t:5.004s
{"count":0,...,"error":"all sources unavailable",...}                  HTTP:503  t:0.0009s  ← breaker open
/health → {"status":"down","usableSources":0}                          HTTP:503
```

The server stayed up, returned a correct 503, and the circuit breaker cut the 4th request from 5s to
**0.9 ms**. When a snapshot exists it serves that instead, flagged `stale: true`.

**This test found two real bugs**, which is the argument for running it:
- `/health` reported `"ok"` during a total outage, because OpenSky is polled every 20s and hadn't
  accumulated enough failures to trip its threshold. One under-sampled source held the light green.
  Fixed: health now counts sources that are *actually usable right now*.
- A total outage returned `count: 0` with no error — **identical to "no aircraft here."** A client
  couldn't distinguish an empty sky from a dead backend. Fixed: `error` field plus a 503.

### 4c. Concurrency — where the worst bug was

Testing 6 simultaneous requests for the same viewport:

```
req 1: count=0    req 2: count=128   req 3: count=0
req 4: count=0    req 5: count=0     req 6: count=0
```

**Five of six users got an empty map.** Each request fired its own upstream fetch, the per-source
rate limiter skipped all but the first, and the skipped ones returned zero aircraft with no error.
This is the precise failure the "one poller, many readers" principle exists to prevent — and my
first implementation didn't actually implement it.

Two fixes:
- **Single-flight**: concurrent callers for the same viewport now share one in-flight refresh, plus a
  1s snapshot TTL.
- **Bounded slot queue**: rate limits are per-source and *global*, so a second viewport in the same
  second was also being starved. Sources now reserve and wait for their next slot instead of being
  skipped — capped at 4s, beyond which the source is genuinely skipped.

After:
```
8 concurrent, SAME viewport      → all 8: count=118, sources=4    PASS
5 concurrent, DIFFERENT viewports → 110, 86, 493, 90, 105          PASS
```

**The honest cost of that fix:** burst latency rose to 3.3s (same viewport) and up to 6s (five
different viewports), and congested sources get dropped from the merge (`sources=2` instead of 4).
Correctness bought at the price of latency.

**Which points at the real production design.** This server fetches *on request*. It should poll
chosen regions *continuously in the background* and serve every request from the snapshot instantly.
Then the rate limit is a background concern and users always get a sub-millisecond response. That's
a decision about which regions you care about, so it's yours to make — but it's the single most
important change before this is real.

### 4d. Failure modes you should expect

| Failure | Likelihood | Effect with this design | What you'd do |
|---|---|---|---|
| One community feed 5xx/times out | **Common** | None — other three cover it | Nothing; breaker handles it |
| A feed returns empty for a region | **Common** (saw adsb.fi do this at Mumbai) | Slight coverage dip | Nothing |
| One feed disappears permanently | Plausible over years | Delete one array entry | ~2 min of work |
| OpenSky quota exhausted | **Likely if you poll hard** | Lose ~10% coverage | Back off to 20s+; register; feed them |
| adsbdb/hexdb down | Occasional | Cached aircraft unaffected; new ones lack identity | Serve position-only, backfill later |
| **All four position feeds down** | Rare | 503 + last-good snapshot | Show "reconnecting" honestly |
| Region has no receivers | **Certain** in Africa/oceans | Genuinely no data | Say "outside coverage" — don't fake it |

### 4e. The honest reliability verdict

- **No SLA exists.** airplanes.live states this explicitly. These are volunteers paying for bandwidth.
- **Individually**, each source is roughly "a good hobby project" — fine most of the time, occasionally
  flaky, with no obligation to you.
- **Combined with breakers, merging and stale-serving, the effective availability is high**, because
  all four failing simultaneously requires four independent operators to break at once.
- **The real risk isn't downtime, it's disappearance.** ADS-B Exchange went commercial in 2023 and the
  community scattered. Any of these could do the same. Your insurance is that the adapter layer is
  ~15 lines per source — including your own receiver, which nobody can take away.

**So: reliable enough for a real product?** Yes for a consumer app where a 30-second gap is a
non-event. No for anything operational — dispatch, safety, ATC-adjacent — and their terms say the
same. If someone would be harmed by a wrong or missing aircraft, buy a commercial feed.

---

## 5. What you can and can't build on this

**Comfortably:**
- Live map of aircraft over any well-covered region
- "What is flying overhead right now" with full aircraft identity and photos
- Spotter tools — rare type alerts, military (`/mil`), squawk watching (7500/7600/7700)
- Airport activity boards driven by observed movements
- Personal flight logging and history you accumulate yourself

**Not without paying:**
- Scheduled times, gates, terminals, delay status (→ AeroDataBox, ~$1–15/mo)
- Ocean, Africa, central Asia coverage (→ FR24 Essential $90/mo)
- Anything with an uptime guarantee

---

## 6. Before this is production

`server.mjs` is a correct, tested prototype — not a finished service. Still missing:

- [ ] **Background regional pollers** (see 4c) — the biggest one. Poll continuously, serve from
      snapshot, so requests never wait on a rate limit.
- [ ] **Per-client viewport filtering.** Today `/stream` sends every aircraft to every subscriber.
- [ ] **Delta encoding.** Send changed aircraft only after the first frame.
- [ ] **Snap viewports to a grid.** Two users on slightly different viewports still cause two
      independent polls; rounding to a coarse grid makes them share one.
- [ ] **Persistent enrichment cache.** Currently a JSON file; move to SQLite/Redis to survive scale.
- [ ] **Attribution UI.** ODbL requires crediting adsb.lol; planespotters requires the photographer.
- [ ] **A local receiver as a source** — highest-value addition, ~15 lines pointing at local `readsb`.

**A note on stack choice:** this is deliberately written with zero dependencies, so it commits you
to nothing. Dropping it into a Next.js route handler, a standalone Fastify service, or a Python
worker are all reasonable, and they trade off differently.

---

## 7. Run it yourself

```bash
node server.mjs

curl "localhost:8080/api/aircraft?lat=51.47&lon=-0.45&radius=150"   # merged positions
curl "localhost:8080/api/aircraft/4ca2c9?callsign=EIN529"           # identity + route + photo
curl "localhost:8080/health"                                        # per-source uptime & latency
curl -N "localhost:8080/stream?lat=51.47&lon=-0.45&radius=100"      # live SSE
```

Reproduce the reliability tests:
```bash
python3 scratchpad/soak.py 600      # sustained soak
python3 scratchpad/coverage.py      # coverage comparison
```
