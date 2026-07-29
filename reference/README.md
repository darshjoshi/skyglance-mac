# Reference implementation (Node)

**The Mac app does not use any of this.** `app/` talks to the flight feeds directly over HTTPS —
it never contacts localhost, and there is no configurable base URL. You do not need Node installed
to build or run SkyGlance.

These two files are the prototype the Swift code was ported *from*, kept because they are a
complete, readable, dependency-free version of the same architecture that you can run and poke at
in about ten seconds. Running both at once simply doubles your load on the upstream feeds.

## `server.mjs` — the backend

Zero dependencies, Node 18+. Merges three ADS-B feeds, applies per-source rate limiting and circuit
breakers, enriches aircraft with routes and photographs, and serves both JSON and SSE.

```bash
node reference/server.mjs

curl "localhost:8080/api/aircraft?lat=51.47&lon=-0.45&radius=150"
curl "localhost:8080/health"
curl -N "localhost:8080/stream?lat=51.47&lon=-0.45&radius=150"
```

`/health` returns 503 when no source is currently usable, rather than reporting "ok" with zero
aircraft — a quiet sky and a total outage must not look identical.

Known limitation: it fetches on request rather than polling in the background, which is fine for a
prototype and wrong for anything real. The Swift app does not have this problem.

## `overhead.mjs` — the geometry layer, plus a CLI

Elevation angle, compass bearing, and closest-point-of-approach. `app/Sources/OverheadKit/Geometry.swift`
is a direct port.

```bash
node reference/overhead.mjs 51.4700 -0.4543
```

Prints what is overhead now, what will be within ~90 seconds, and what is merely nearby — the same
three groupings the Mac app's panel uses.

See [`docs/FREE-STACK.md`](../docs/FREE-STACK.md) for how the backend is put together and what was
measured, and [`docs/OVERHEAD-DETECTION.md`](../docs/OVERHEAD-DETECTION.md) for the geometry and why
prediction beyond ~90 seconds is not trustworthy.
