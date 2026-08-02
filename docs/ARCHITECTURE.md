# Architecture

**Target:** a macOS app with a live preview and a widget, answering "what is flying overhead?"
Builds on the measured findings in [OVERHEAD-DETECTION.md](./OVERHEAD-DETECTION.md).

**Requires** macOS 13 or newer to run, and Xcode 15 or newer to build. Developed against Xcode 26.6,
Swift 6.3.3, macOS 27.0. There are no external package dependencies.

---

## The one constraint that shapes the design

"Live preview" and "widget" are two different things technically, and the difference matters:

**A widget cannot be live.** WidgetKit renders an extension into a static snapshot on a schedule
the system controls. It isn't a running process, can't animate, and can't tick every second.

Good news, verified with Apple: **macOS widgets have no daily reload budget.** From an Apple
Frameworks Engineer on the developer forums: *"On Mac, Widgets do not. On iOS the limit is 72 manual
refreshes per day."* So you can refresh far more often than on iPhone — but the floor is still
minutes, not seconds, because each refresh relaunches the extension to re-render.

Now combine that with the measured prediction data: **the trustworthy lead time is 30–60 seconds**
(at 240s, 77% of aircraft are >2 km from prediction). A widget refreshing every few minutes can
therefore *never* deliver "look up right now."

**So the live surface and the widget must be different components with different jobs:**

| Surface | Technology | Update rate | Job |
|---|---|---|---|
| **Menu bar item** | `NSStatusItem`, your own process | **1–3 s, truly live** | Glanceable: `✈ 59° WSW A333` |
| **Preview window** | SwiftUI + MapKit | **1 s + interpolation** | The map / sky view you open and watch |
| **Notification** | `UNUserNotificationCenter` | Event-driven, 45 s lead | **"Look up now — WSW, 59° up, A330"** |
| **Widget** | WidgetKit + App Group | 1–5 min | Ambient: overhead now, today's count, last rare sighting |

The notification, not the widget, delivers the magic. The widget is the ambient/at-rest surface.

---

## Component design

```
┌──────────────────────────────────────────────┐
│  OverheadKit (shared Swift package)           │  ← already proven, see below
│  · feed clients (adsb.lol + fallbacks)        │
│  · geometry: elevation / bearing / CPA        │
│  · interest rules, weather gate               │
└───────────────┬──────────────────────────────┘
                │
   ┌────────────┴────────────┬──────────────────────┐
┌──▼──────────────┐  ┌───────▼────────┐  ┌──────────▼─────────┐
│ Menu bar agent  │  │ Preview window │  │  Widget extension  │
│ LSUIElement     │  │ SwiftUI+MapKit │  │  WidgetKit         │
│ polls 1–3 s     │  │ 60fps interp.  │  │  reads App Group   │
│ fires notifs    │  │                │  │  1–5 min timeline  │
└────────┬────────┘  └────────────────┘  └──────────▲─────────┘
         │                                          │
         └──────────► App Group container ──────────┘
                      (latest snapshot + logbook)
```

**Why the menu bar agent owns the polling:** it's the only always-running process. It writes the
current state into the shared App Group container; the widget just reads it. That means the widget
never makes a network request, so its refresh cost is trivial and its data is as fresh as the last
agent tick.

> The agent is **not** marked `LSUIElement`, despite being a menu bar app. It calls
> `setActivationPolicy(.accessory)` at launch instead, which produces the same result — no Dock
> icon, no menu bar of its own — but leaves it registered with Location Services. With the plist key
> set, `requestWhenInUseAuthorization()` shows no dialog at all and the status stays
> `.notDetermined` forever. Measured across all four combinations of that key and the signing
> identity, *Use My Location* works only with the key false **and** a Developer ID signature.

---

## Alert delivery: one decision, two channels

Deciding *whether* to interrupt and deciding *how* are separate concerns, and keeping them separate
is what stops the two channels drifting apart.

```
        scorer ──► interest?
                      │
                      ▼
        ┌──── choose channel ────┐        popups enabled?
        │                        │        user present (idle < 5 min, unlocked)?
        │                        │        no VoiceOver / Switch Control?
        │                        │        menu bar anchor findable?
        ▼                        ▼
   popup governor          notification governor
   (looser budget)          (stricter budget)
        │                        │
        └────► shared "already alerted today" ◄────┘
                      │
                      ▼
          card under the ✈   /   Notification Center
```

**The channel is chosen before the budget is applied**, not after. An earlier version decided from
presence alone and only discovered inside delivery that the card could not be placed — so a hidden
menu bar item produced a real system notification governed by the *popup's* looser budget, and the
footer never counted it.

**Two budgets, one memory.** The governors keep separate volume and cadence state — that is the
whole point of a second channel — but share the set of aircraft that have already interrupted you.
Without that, seeing a popup and then locking the screen fired a second alert for the same aircraft
through the other channel. The shared set carries its own day stamp, because each governor rolls its
own budget over independently and the second one to wake after midnight would otherwise clear
records the first had already written that day.

**Assistive technology always gets the notification.** The card is a non-activating panel that never
becomes key, so VoiceOver cannot reach it and its only pause affordance is the mouse. Showing one
*instead of* a notification would remove the alert entirely rather than degrade it.

---

## Proven already

The whole data + geometry layer runs natively in Swift with **zero dependencies** — no server, no
Node. Compiled and run on this machine:

```
$ ./OverheadProbe 51.4700 -0.4543
HTTP 200 in 0.52s, 122148 bytes, 178 aircraft airborne

OVERHEAD WITHIN 90s (the only horizon worth trusting)
  EDV5328 CRJ9 in  50s  passing 4.3 km NNW  50 deg up
  SAS904  A333 in  52s  passing 1.8 km WSW  59 deg up

NEAREST
  DAL2195 B739   2.5 km   2 deg up  ESE
  SAS904  A333   8.8 km  20 deg up  WSW
```

That's `URLSession` + `Codable` + the same verified geometry, ~200 lines. It ports directly into the
app as `OverheadKit`.

Two data gotchas already handled in that code:
- `alt_baro` is a **number in flight and the string `"ground"` on the ground** — needs a custom
  `Decodable` enum or it fails to parse. This is the single most common ADS-B parsing bug.
- `alt_baro` can read **slightly negative** near sea level in low pressure, producing a negative
  elevation angle. Clamp at zero.

---

## macOS specifics to get right

| Item | Requirement |
|---|---|
| **App Group** | Required to share data app ↔ widget. Needs a Team ID — a free Apple ID works for local dev; App Store distribution needs the paid program. |
| **Sandbox entitlement** | `com.apple.security.network.client` for outbound requests. |
| **Menu-bar-only** | `LSUIElement = true` in Info.plist so there's no Dock icon. |
| **Launch at login** | `SMAppService.mainApp.register()` — the modern API; login items are deprecated. |
| **Widget placement** | macOS puts widgets in Notification Center and on the Desktop. |
| **Location** | Either CoreLocation, or a settings field. A fixed coordinate is better here — your house doesn't move, and it avoids a permission prompt. |
| **Logbook storage** | SwiftData in the App Group container, so the widget can read stats. |

---

## Build order

**1 — OverheadKit package**
Port `OverheadProbe.swift` into a Swift package: feed client with the three-source merge and circuit
breaking (logic already proven in `server.mjs`), geometry (already verified 11/11), weather gate.

**2 — Menu bar agent**
`NSStatusItem` showing the single most interesting thing overhead. Polls every 2 s. Writes snapshot
to the App Group. This alone is already a usable product.

**3 — Notifications**
Interest rules + 45 s lead + weather/daylight gate. This is the feature that makes it magic, and the
one that needs the most tuning to avoid being spam.

**4 — Preview window**
SwiftUI + MapKit, aircraft as annotations, dead-reckoning interpolation between updates so they glide
rather than jump. Optionally a "sky dome" view — bearing around, elevation as distance from centre —
which maps far better to actually looking up than a top-down map does.

**5 — Widget**
Small: what's overhead now. Medium: overhead + next inbound + today's count. Large: add the day's
notable sightings. Reads the App Group snapshot; 1–5 min timeline.

**6 — Logbook**
SwiftData: every aircraft ever seen, first-sightings, personal records. The retention mechanic.

---

## Open decisions

1. **Your coordinates** — still the blocker for step zero (does your sky even have traffic).
2. **Menu bar only, or a real windowed app?** Menu-bar-only is simpler and honestly fits better.
3. **Map or sky dome for the preview?** A dome matches "where do I look" much better than a map, but
   it's a custom view rather than free MapKit.
4. **Free Apple ID or paid developer account?** Free works for running it on your own Mac. Paid
   ($99/yr) is only needed to ship it to anyone else.
