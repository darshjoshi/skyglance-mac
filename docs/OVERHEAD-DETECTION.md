# Detecting what is overhead — what it actually takes

Working code: [`overhead.mjs`](../reference/overhead.mjs) — geometry engine, 11/11 known-answer tests passing.
Data layer: [`server.mjs`](../reference/server.mjs). Background: [FREE-STACK.md](./FREE-STACK.md).

---

## The short version

The data problem is **solved and free**. The hard parts are three things nobody expects:

1. **"Over" is an angle, not a distance.** A radius filter gives you the wrong aircraft entirely.
2. **You can only predict ~60 seconds ahead.** Measured. This caps what the product can promise.
3. **It gets boring on day 3.** Every plane overhead is "a 737 to Chicago." Retention is the real
   design problem, not data.

---

## 1. Why "over" is an angle

A 20 km radius filter returns an airliner at 38,000 ft that's 19 km away — which sits **32° above the
horizon**, a speck near the treeline. It also returns a helicopter at 800 ft that's 19 km away, at
**0.7°** — completely invisible, behind buildings.

What matters is the **elevation angle**: `atan(altitude / ground_distance)`.

| Elevation | Meaning |
|---|---|
| ≥ 60° | Genuinely overhead — crane your neck |
| 30–60° | High and easy to spot |
| 15–30° | Visible but low |
| < 15° | Horizon — usually behind something |

Plus the **bearing** (which way to look) and the **slant range** (how big it'll appear). An airliner
~40 m long stops being resolvable to the naked eye past roughly 50 km slant range in clear air.

`overhead.mjs` computes all of it. Verified against known answers:

```
PASS elevation, 1km out & 1km up      got 45.000   want 45
PASS elevation directly overhead      got 90.000   want 90
PASS elevation, 10km out & 1km up     got  5.711   want 5.71
PASS bearing due north / due east     got  0.000 / 89.944
PASS CPA seconds (10km south @360kt)  got 53.996   want 54
PASS CPA ground miss distance         got  0.000   want 0
PASS CPA t=0 when flying perpendicular
PASS altitude at CPA after descent    got 8200     want 8200
11 passed, 0 failed
```

Live, from a point under a major airport's approach path:

```
Conditions: 14% cloud, 46 km visibility, daylight — clear enough to spot aircraft
173 aircraft airborne within 60 nm

COMING OVERHEAD
  UAL967   B763  in 4m38s  passing 0.0 km SW  at  1,804 ft  88° up
  ENY3816  E75L  in 5m20s  passing 0.1 km NW  at 31,000 ft  90° up

NEAREST RIGHT NOW
  AAL2490  B738   2.7 km away   3° up  SE   visible
  EDV5010  CRJ9   7.1 km away   4° up  S    visible
```

---

## 2. The prediction limit — the single most important number

"Overhead in 4m38s" assumes the aircraft flies straight. They don't. Measured: snapshot 50
aircraft near Heathrow, extrapolate each from track + ground speed alone, then re-fetch and compare.

| Horizon | Median error | p90 error | Worst | % off by >2 km |
|---|---|---|---|---|
| **30 s** | **0.11 km** | 0.42 km | 1.4 km | **0%** |
| **60 s** | **0.30 km** | 1.91 km | 3.7 km | **9%** |
| **120 s** | **1.15 km** | 6.69 km | 10.0 km | **29%** |
| **240 s** | **5.98 km** | 21.86 km | 24.7 km | **77%** |

**Read this as a product constraint, not a stat.** Straight-line prediction is excellent to 30 s, good
to 60 s, and worthless by 240 s — where **77% of aircraft are more than 2 km from the prediction** and
the median miss is 6 km. Aircraft on approach turn constantly; a fixed heading stops meaning anything.

So:
- **Notify 30–60 seconds ahead.** That's enough time to walk outside, and it's the window you can trust.
- **Never show "in 4m38s."** The demo output above does exactly that, and it is misleading — at
  that horizon nearly a third of aircraft will be more than 2 km from where you said.
- Show a countdown only under ~90s. Beyond that, show "inbound" without a promise.

This is the constraint that shapes the whole UX, and it's free to respect.

---

## 3. Does your sky actually work?

Coverage is local. Free feeds depend on a volunteer having a receiver near you. Measured, 40 nm radius:

| Location | Airborne | Below 10,000 ft |
|---|---|---|
| New York, under an approach path | 99 | 85 |
| New York suburbs | 99 | 87 |
| Suburban London | 31 | 16 |
| Rural Vermont | 9 | 4 |
| **Rural Montana** | **0** | **0** |

**This is step zero for you specifically.** Point the probe at your actual coordinates. If you see
dozens of aircraft below 10,000 ft, the free stack is enough. If you see near zero, either nothing
flies over you or nobody's receiving it — and only your own receiver distinguishes those.

The low-altitude count matters more than the total. High cruising traffic is a dot; the aircraft that
make this product fun are the ones below 10,000 ft.

---

## 4. Visibility — free, and it's half the product

Telling someone to look up at an overcast sky is a broken experience. **Open-Meteo** is free with no
API key and gives cloud cover, visibility and daylight:

```
Conditions: 14% cloud, 46 km visibility, daylight — clear enough to spot aircraft
```

Rule: suppress notifications when cloud cover >80%, or at night unless the aircraft is low enough for
landing lights to be visible. This one filter is the difference between a useful app and a spammy one.

---

## 5. The retention problem — the actual hard part

Day 1 it's magic. Day 3, "a 737 to Chicago" is wallpaper. Everything above is table stakes; **this**
is where the product lives. Signals verified as available and free:

| Signal | Endpoint | Live result when tested |
|---|---|---|
| Military | `/v2/mil` | 110 airborne worldwide (C17×12, K35R×8, C30J×7, H60×6) |
| Emergency squawk | `/v2/squawk/7700` | 0 right now — rare, which is the point |
| Radio failure | `/v2/squawk/7600` | 0 |
| Rare heavies | `/v2/type/A124` | 0 An-124s airborne |
| 747-8 | `/v2/type/B748` | 39 worldwide |
| A380 | `/v2/type/A388` | 36 worldwide |

Combine with things only *you* know, from data you accumulate locally:
- **First-ever sighting** of a registration — the collection mechanic
- **Personal records** — lowest, closest, largest, most in a day
- **Unusual for here** — a type that's never crossed your sky before
- **Streaks** — consecutive days with a new tail number

That turns a live map into something worth opening. It also costs nothing: it's your own history,
which the free feeds let you keep (unlike FR24's 30-day storage rule).

---

## 6. Should you buy a receiver?

For this specific product, **yes** — it's the one use case where it's unambiguous.

| | Free feeds | Your own receiver |
|---|---|---|
| Coverage of *your* sky | Depends on volunteers nearby | 100%, always |
| Latency | 1–5 s + network | **~1 s, no network** |
| Rate limit | ~1 req/s shared | None |
| Low-altitude aircraft | Often missed | **Excellent — you're underneath them** |
| Cost | $0 | ~$30–80 once |
| Works if internet dies | No | Yes |

The low-altitude row is decisive. Distant receivers have line-of-sight problems with aircraft below
~5,000 ft — exactly the ones passing over your house. A receiver on your own windowsill sees them all.

Plus feeding FlightAware raises your free AeroAPI allowance from $5 to **$20/month**.

---

## 7. What building it actually involves

**Phase 1 — does it work here** (30 min)
- Run the coverage probe on your real coordinates
- Run `overhead.mjs` on your coordinates; watch it for an evening

**Phase 2 — the core loop**
- Background poller for one small region (your sky), not on-demand fetching
- Elevation/CPA per aircraft, notify at 30–60 s lead
- Weather gate on notifications
- Local history: every aircraft you've ever seen

**Phase 3 — what makes it stick**
- First-seen / rare-type / military / personal-record detection
- A "look up NOW — WSW, 45° up, 747" push notification
- Your logbook: everything that's crossed your sky

**Phase 4 — optional**
- Your own receiver, added as one more source (~15 lines)
- Photos via planespotters, routes via adsbdb — both already working in `server.mjs`

---

## Run it

```bash
node reference/overhead.mjs <lat> <lon>
```
