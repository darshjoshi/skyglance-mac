/**
 * Free-stack flight data backend — reference implementation, zero dependencies.
 *
 *   node server.mjs
 *   curl "localhost:8080/api/aircraft?lat=51.47&lon=-0.45&radius=150"
 *   curl "localhost:8080/api/aircraft/406a3d"
 *   curl "localhost:8080/health"
 *   curl -N "localhost:8080/stream?lat=51.47&lon=-0.45&radius=150"
 *
 * Design notes are in FREE-STACK.md.
 */
import http from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";

const PORT = Number(process.env.PORT ?? 8080);
const UA = "SkyGlance-reference/0.1 (+https://github.com/darshjoshi/skyglance-mac)";
const CACHE_DIR = join(process.cwd(), ".cache");

// ── HTTP helper ───────────────────────────────────────────────────────────────

async function getJSON(url, { timeout = 8000 } = {}) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  try {
    const res = await fetch(url, {
      signal: ctl.signal,
      headers: { accept: "application/json", "user-agent": UA },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

// ── Position sources ──────────────────────────────────────────────────────────
// Each adapter returns a normalized array. Adding a source (including your own
// receiver's readsb output) means adding one entry here and nothing else.

const numeric = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** readsb/tar1090 JSON — shared by adsb.lol, airplanes.live, adsb.fi and your own receiver. */
function normalizeReadsb(ac) {
  return {
    hex: ac.hex?.trim().toLowerCase(),
    callsign: ac.flight?.trim() || null,
    registration: ac.r?.trim() || null,
    type: ac.t?.trim() || null,
    lat: numeric(ac.lat),
    lon: numeric(ac.lon),
    // alt_baro is the string "ground" when on the ground — the classic ADS-B bug.
    altitude: ac.alt_baro === "ground" ? 0 : numeric(ac.alt_baro),
    onGround: ac.alt_baro === "ground",
    groundSpeed: numeric(ac.gs),
    track: numeric(ac.track),
    verticalRate: numeric(ac.baro_rate),
    squawk: ac.squawk ?? null,
    emergency: ac.emergency && ac.emergency !== "none" ? ac.emergency : null,
    seenPos: numeric(ac.seen_pos) ?? 999,
    positionSource: ac.mlat?.length ? "mlat" : ac.tisb?.length ? "tisb" : "adsb",
    description: ac.desc ?? null,
    operator: ac.ownOp ?? null,
  };
}

/** OpenSky returns positional arrays, not objects. Indices are fixed by their spec. */
function normalizeOpenSky(s) {
  return {
    hex: s[0]?.trim().toLowerCase(),
    callsign: s[1]?.trim() || null,
    registration: null,
    type: null,
    lat: numeric(s[6]),
    lon: numeric(s[5]),
    altitude: numeric(s[7]) != null ? Math.round(s[7] * 3.28084) : null,
    onGround: Boolean(s[8]),
    groundSpeed: numeric(s[9]) != null ? Math.round(s[9] * 1.94384) : null,
    track: numeric(s[10]),
    verticalRate: numeric(s[11]) != null ? Math.round(s[11] * 196.85) : null,
    squawk: s[14] ?? null,
    emergency: null,
    seenPos: s[3] ? Math.max(0, Math.floor(Date.now() / 1000) - s[3]) : 999,
    positionSource: "adsb",
    description: null,
    operator: null,
  };
}

const bbox = (lat, lon, nm) => {
  const dLat = nm / 60;
  const dLon = nm / (60 * Math.max(Math.cos((lat * Math.PI) / 180), 0.01));
  return { lamin: lat - dLat, lomin: lon - dLon, lamax: lat + dLat, lomax: lon + dLon };
};

const SOURCES = [
  {
    name: "adsb.lol",
    minIntervalMs: 1000,
    url: (lat, lon, r) => `https://api.adsb.lol/v2/point/${lat}/${lon}/${r}`,
    parse: (d) => (d.ac ?? []).map(normalizeReadsb),
  },
  {
    name: "airplanes.live",
    minIntervalMs: 1000, // documented hard limit: 1 req/sec
    url: (lat, lon, r) => `https://api.airplanes.live/v2/point/${lat}/${lon}/${r}`,
    parse: (d) => (d.ac ?? []).map(normalizeReadsb),
  },
  {
    name: "adsb.fi",
    minIntervalMs: 1000,
    url: (lat, lon, r) => `https://opendata.adsb.fi/api/v2/lat/${lat}/lon/${lon}/dist/${r}`,
    parse: (d) => (d.aircraft ?? d.ac ?? []).map(normalizeReadsb),
  },
  {
    name: "opensky",
    minIntervalMs: 20000, // quota is the constraint here, not politeness
    url: (lat, lon, r) => {
      const b = bbox(lat, lon, r);
      return `https://opensky-network.org/api/states/all?lamin=${b.lamin.toFixed(4)}&lomin=${b.lomin.toFixed(4)}&lamax=${b.lamax.toFixed(4)}&lomax=${b.lomax.toFixed(4)}`;
    },
    parse: (d) => (d.states ?? []).map(normalizeOpenSky),
  },
];

// ── Circuit breaker ───────────────────────────────────────────────────────────
// None of these services offer an SLA. Assume every one of them will fail.

const health = new Map(
  SOURCES.map((s) => [
    s.name,
    { ok: 0, fail: 0, consecutiveFails: 0, openUntil: 0, lastMs: null, lastCount: null, lastError: null, lastAt: 0 },
  ])
);

const FAILS_BEFORE_OPEN = 3;
const BREAKER_COOLDOWN_MS = 30_000;

// Rate limits are per-source and global, not per-viewport. Simply skipping when
// the window hasn't elapsed means the second distinct viewport in a given second
// gets nothing. Instead, reserve the next slot and wait for it — bounded, so a
// congested source is skipped rather than queueing forever.
const nextSlot = new Map(SOURCES.map((s) => [s.name, 0]));
const MAX_QUEUE_WAIT_MS = 4000;

async function reserveSlot(src) {
  const now = Date.now();
  const slot = Math.max(nextSlot.get(src.name), now);
  const waitMs = slot - now;
  if (waitMs > MAX_QUEUE_WAIT_MS) return false;
  nextSlot.set(src.name, slot + src.minIntervalMs);
  if (waitMs > 0) await new Promise((r) => setTimeout(r, waitMs));
  return true;
}

async function fetchSource(src, lat, lon, radius) {
  const h = health.get(src.name);
  if (Date.now() < h.openUntil) return { name: src.name, skipped: "circuit-open", aircraft: [] };
  if (!(await reserveSlot(src))) return { name: src.name, skipped: "rate-limit", aircraft: [] };

  h.lastAt = Date.now();
  const t0 = performance.now();
  try {
    // Short timeout: a slow source must not hold up the merge, the others cover it.
    const data = await getJSON(src.url(lat, lon, radius), { timeout: 5000 });
    const aircraft = src.parse(data).filter((a) => a.hex && a.lat != null && a.lon != null);
    h.ok++;
    h.consecutiveFails = 0;
    h.lastMs = Math.round(performance.now() - t0);
    h.lastCount = aircraft.length;
    h.lastError = null;
    return { name: src.name, aircraft };
  } catch (err) {
    h.fail++;
    h.consecutiveFails++;
    h.lastError = err.message;
    h.lastMs = Math.round(performance.now() - t0);
    if (h.consecutiveFails >= FAILS_BEFORE_OPEN) h.openUntil = Date.now() + BREAKER_COOLDOWN_MS;
    return { name: src.name, error: err.message, aircraft: [] };
  }
}

// ── Merge ─────────────────────────────────────────────────────────────────────
// Union by ICAO hex. On conflict the freshest position wins; fields absent from
// the winner are backfilled from the others, so OpenSky's extra aircraft still
// get adsb.lol's registration and type where available.

function merge(results) {
  const byHex = new Map();
  const contributors = new Map();

  for (const { name, aircraft } of results) {
    for (const ac of aircraft) {
      const existing = byHex.get(ac.hex);
      if (!existing) {
        byHex.set(ac.hex, { ...ac, sources: [name] });
        contributors.set(ac.hex, new Set([name]));
        continue;
      }
      contributors.get(ac.hex).add(name);
      const winner = ac.seenPos < existing.seenPos ? ac : existing;
      const loser = winner === ac ? existing : ac;
      const combined = { ...winner };
      for (const [k, v] of Object.entries(loser)) {
        if ((combined[k] === null || combined[k] === undefined) && v != null) combined[k] = v;
      }
      combined.sources = [...contributors.get(ac.hex)];
      byHex.set(ac.hex, combined);
    }
  }
  return [...byHex.values()];
}

// ── Enrichment ────────────────────────────────────────────────────────────────
// hex → aircraft and callsign → route are effectively immutable. Cache forever,
// including negative results, or you will hammer volunteer-run services.

const aircraftCache = new Map();
const routeCache = new Map();

async function firstOf(fns) {
  for (const fn of fns) {
    try {
      const v = await fn();
      if (v) return v;
    } catch {
      /* try next provider */
    }
  }
  return null;
}

async function lookupAircraft(hex) {
  if (aircraftCache.has(hex)) return aircraftCache.get(hex);
  const result = await firstOf([
    async () => {
      const d = await getJSON(`https://api.adsbdb.com/v0/aircraft/${hex}`);
      const a = d?.response?.aircraft;
      return a && { registration: a.registration, type: a.type, icaoType: a.icao_type,
                    manufacturer: a.manufacturer, owner: a.registered_owner,
                    country: a.registered_owner_country_name, source: "adsbdb" };
    },
    async () => {
      const d = await getJSON(`https://hexdb.io/api/v1/aircraft/${hex}`);
      return d?.Registration && { registration: d.Registration, type: d.Type,
                                  icaoType: d.ICAOTypeCode, manufacturer: d.Manufacturer,
                                  owner: d.RegisteredOwners, country: null, source: "hexdb" };
    },
  ]);
  aircraftCache.set(hex, result); // caches null too — that's deliberate
  return result;
}

async function lookupRoute(callsign) {
  if (!callsign) return null;
  if (routeCache.has(callsign)) return routeCache.get(callsign);
  const result = await firstOf([
    async () => {
      const d = await getJSON(`https://api.adsbdb.com/v0/callsign/${callsign}`);
      const r = d?.response?.flightroute;
      return r && {
        airline: r.airline?.name ?? null,
        origin: r.origin && { icao: r.origin.icao_code, iata: r.origin.iata_code,
                              name: r.origin.name, lat: r.origin.latitude, lon: r.origin.longitude },
        destination: r.destination && { icao: r.destination.icao_code, iata: r.destination.iata_code,
                                        name: r.destination.name, lat: r.destination.latitude,
                                        lon: r.destination.longitude },
        source: "adsbdb",
      };
    },
    async () => {
      const d = await getJSON(`https://hexdb.io/api/v1/route/icao/${callsign}`);
      if (!d?.route?.includes("-")) return null;
      const [origin, destination] = d.route.split("-");
      return { airline: null, origin: { icao: origin }, destination: { icao: destination }, source: "hexdb" };
    },
  ]);
  routeCache.set(callsign, result);
  return result;
}

async function lookupPhoto(registration) {
  if (!registration) return null;
  try {
    const d = await getJSON(`https://api.planespotters.net/pub/photos/reg/${registration}`);
    const p = d?.photos?.[0];
    // Attribution is a condition of use, so the photographer travels with the URL.
    return p && { thumbnail: p.thumbnail_large?.src ?? p.thumbnail?.src,
                  link: p.link, photographer: p.photographer };
  } catch {
    return null;
  }
}

// ── Snapshot store ────────────────────────────────────────────────────────────
// Serving slightly stale data beats serving an error. Every response says how
// old it is so the client can decide.

const snapshots = new Map();
const MAX_SNAPSHOTS = 500; // distinct viewports; without a cap this grows forever
const key = (lat, lon, r) => `${lat},${lon},${r}`;

function storeSnapshot(k, snap) {
  if (snapshots.size >= MAX_SNAPSHOTS && !snapshots.has(k)) {
    snapshots.delete(snapshots.keys().next().value); // Map preserves insertion order → oldest first
  }
  snapshots.set(k, snap);
}

async function refresh(lat, lon, radius) {
  const results = await Promise.all(SOURCES.map((s) => fetchSource(s, lat, lon, radius)));
  const live = results.filter((r) => !r.skipped && !r.error);
  const aircraft = merge(results);
  const k = key(lat, lon, radius);
  const prev = snapshots.get(k);

  if (live.length === 0) {
    if (prev) return { ...prev, degraded: true, stale: true };
    // Rate-limited with nothing cached is a different problem from every source
    // being down, and the client should be told which it is.
    const rateLimited = results.every((r) => r.skipped === "rate-limit");
    return {
      aircraft: [], at: Date.now(), sources: [], degraded: true, stale: false,
      error: rateLimited ? "rate limited, no cached data yet" : "all sources unavailable",
    };
  }

  const snap = {
    aircraft,
    at: Date.now(),
    sources: live.map((r) => ({ name: r.name, count: r.aircraft.length })),
    degraded: live.length < 2,
    stale: false,
  };
  storeSnapshot(k, snap);
  return snap;
}

// Single-flight: concurrent callers for the same viewport share one upstream
// refresh instead of each firing their own. Without this, N simultaneous users
// trigger N fetches, the per-source rate limiter skips most of them, and those
// callers get an empty result — the failure this design exists to prevent.
const inflight = new Map();
const SNAPSHOT_TTL_MS = 1000;

function getSnapshot(lat, lon, radius) {
  const k = key(lat, lon, radius);
  const cached = snapshots.get(k);
  if (cached && Date.now() - cached.at < SNAPSHOT_TTL_MS) return Promise.resolve(cached);
  const pending = inflight.get(k);
  if (pending) return pending;
  const p = refresh(lat, lon, radius).finally(() => inflight.delete(k));
  inflight.set(k, p);
  return p;
}

// ── Persistence for the enrichment caches ─────────────────────────────────────

async function saveCaches() {
  try {
    await mkdir(CACHE_DIR, { recursive: true });
    await writeFile(join(CACHE_DIR, "enrichment.json"),
      JSON.stringify({ aircraft: [...aircraftCache], routes: [...routeCache] }));
  } catch (e) {
    console.error("cache save failed:", e.message);
  }
}

async function loadCaches() {
  try {
    const raw = JSON.parse(await readFile(join(CACHE_DIR, "enrichment.json"), "utf8"));
    for (const [k, v] of raw.aircraft ?? []) aircraftCache.set(k, v);
    for (const [k, v] of raw.routes ?? []) routeCache.set(k, v);
    console.log(`cache: ${aircraftCache.size} aircraft, ${routeCache.size} routes restored`);
  } catch {
    console.log("cache: starting empty");
  }
}

// ── HTTP API ──────────────────────────────────────────────────────────────────

const json = (res, code, body) => {
  const payload = JSON.stringify(body);
  res.writeHead(code, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  try {
    if (p === "/health") {
      // Judge on sources that are actually usable right now. Counting a source
      // as healthy just because it hasn't been polled enough to fail yet reports
      // "ok" during a total outage.
      const usable = [...health.values()].filter(
        (h) => Date.now() >= h.openUntil && h.consecutiveFails < FAILS_BEFORE_OPEN && h.ok > 0
      ).length;
      return json(res, usable === 0 ? 503 : 200, {
        status: usable === 0 ? "down" : usable < 2 ? "degraded" : "ok",
        usableSources: usable,
        sources: Object.fromEntries(
          [...health.entries()].map(([name, h]) => [name, {
            uptime: h.ok + h.fail ? `${((100 * h.ok) / (h.ok + h.fail)).toFixed(1)}%` : "n/a",
            requests: h.ok + h.fail,
            lastLatencyMs: h.lastMs,
            lastCount: h.lastCount,
            lastError: h.lastError,
            circuitOpen: Date.now() < h.openUntil,
          }])
        ),
        cache: { aircraft: aircraftCache.size, routes: routeCache.size },
      });
    }

    if (p === "/api/aircraft") {
      const lat = Number(url.searchParams.get("lat"));
      const lon = Number(url.searchParams.get("lon"));
      const radius = Math.min(Number(url.searchParams.get("radius") ?? 100), 250);
      if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
        return json(res, 400, { error: "lat and lon are required and must be valid coordinates" });
      }
      const snap = await getSnapshot(lat, lon, radius);
      // An empty sky and a total outage both yield zero aircraft. The client has
      // to be able to tell them apart, so the error travels with the response.
      return json(res, snap.error ? 503 : 200, {
        count: snap.aircraft.length,
        ageMs: Date.now() - snap.at,
        stale: snap.stale,
        degraded: snap.degraded,
        error: snap.error ?? null,
        sources: snap.sources,
        aircraft: snap.aircraft,
      });
    }

    const detail = p.match(/^\/api\/aircraft\/([0-9a-fA-F]{6})$/);
    if (detail) {
      const hex = detail[1].toLowerCase();
      const callsign = url.searchParams.get("callsign");
      const [aircraft, route] = await Promise.all([lookupAircraft(hex), lookupRoute(callsign)]);
      const photo = await lookupPhoto(aircraft?.registration);
      return json(res, 200, { hex, aircraft, route, photo });
    }

    if (p === "/stream") {
      const lat = Number(url.searchParams.get("lat"));
      const lon = Number(url.searchParams.get("lon"));
      const radius = Math.min(Number(url.searchParams.get("radius") ?? 100), 250);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
        return json(res, 400, { error: "lat and lon are required" });
      }
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
        "access-control-allow-origin": "*",
      });
      const tick = async () => {
        const snap = await getSnapshot(lat, lon, radius);
        res.write(`data: ${JSON.stringify({
          count: snap.aircraft.length, ageMs: Date.now() - snap.at,
          stale: snap.stale, degraded: snap.degraded, aircraft: snap.aircraft,
        })}\n\n`);
      };
      await tick();
      const interval = setInterval(tick, 2000);
      req.on("close", () => clearInterval(interval));
      return;
    }

    return json(res, 404, { error: "not found", routes: ["/health", "/api/aircraft", "/api/aircraft/:hex", "/stream"] });
  } catch (err) {
    console.error(err);
    return json(res, 500, { error: err.message });
  }
});

await loadCaches();
setInterval(saveCaches, 60_000).unref();
process.on("SIGINT", async () => { await saveCaches(); process.exit(0); });

server.listen(PORT, () => console.log(`free-stack backend listening on http://localhost:${PORT}`));
