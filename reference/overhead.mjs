/**
 * "What's flying over my house?" — the geometry layer.
 *
 *   node overhead.mjs <lat> <lon>
 *
 * A radius filter is the wrong model: an airliner at 38,000 ft that is 5 km away
 * is 62° up in the sky, while a helicopter at 1,000 ft that is 5 km away is 3°
 * up and hidden behind a tree. What matters is the *elevation angle*, the
 * *bearing to look*, and *when it will be closest*.
 */

const R_EARTH_KM = 6371;
const FT_TO_KM = 0.0003048;
const KT_TO_KMS = 0.000514444;
const rad = (d) => (d * Math.PI) / 180;
const deg = (r) => (r * 180) / Math.PI;

export function haversineKm(lat1, lon1, lat2, lon2) {
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_EARTH_KM * Math.asin(Math.sqrt(a));
}

/** Compass bearing from observer to target, 0=N 90=E. */
export function bearingDeg(lat1, lon1, lat2, lon2) {
  const dLon = rad(lon2 - lon1);
  const y = Math.sin(dLon) * Math.cos(rad(lat2));
  const x =
    Math.cos(rad(lat1)) * Math.sin(rad(lat2)) -
    Math.sin(rad(lat1)) * Math.cos(rad(lat2)) * Math.cos(dLon);
  return (deg(Math.atan2(y, x)) + 360) % 360;
}

const COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"];
export const compass = (b) => COMPASS[Math.round(b / 22.5) % 16];

/**
 * Closest point of approach on the aircraft's current heading.
 * Flat local approximation — good to well under a percent inside ~100 km.
 */
export function closestApproach(observer, ac) {
  if (ac.groundSpeed == null || ac.track == null) return null;

  // Local east/north offsets in km.
  const east = haversineKm(observer.lat, observer.lon, observer.lat, ac.lon) *
    (ac.lon < observer.lon ? -1 : 1);
  const north = haversineKm(observer.lat, observer.lon, ac.lat, observer.lon) *
    (ac.lat < observer.lat ? -1 : 1);

  const speedKms = ac.groundSpeed * KT_TO_KMS;
  const vEast = speedKms * Math.sin(rad(ac.track));
  const vNorth = speedKms * Math.cos(rad(ac.track));
  const vSq = vEast ** 2 + vNorth ** 2;
  if (vSq === 0) return null;

  // Minimise |p + v·t| over t.
  const t = -(east * vEast + north * vNorth) / vSq;
  const cEast = east + vEast * t;
  const cNorth = north + vNorth * t;
  const groundKm = Math.hypot(cEast, cNorth);

  // Altitude at CPA, accounting for climb/descent (baro_rate is ft/min).
  const altAtCpaFt = Math.max(0, (ac.altitude ?? 0) + ((ac.verticalRate ?? 0) / 60) * t);

  return {
    secondsAway: t,
    approaching: t > 0,
    groundKm,
    altitudeFt: Math.round(altAtCpaFt),
    elevationDeg: groundKm === 0 ? 90 : deg(Math.atan2(altAtCpaFt * FT_TO_KM, groundKm)),
    bearingDeg: (deg(Math.atan2(cEast, cNorth)) + 360) % 360,
  };
}

/** Everything you need to decide whether to walk outside and look up. */
export function describe(observer, ac) {
  const groundKm = haversineKm(observer.lat, observer.lon, ac.lat, ac.lon);
  // alt_baro can read slightly negative near sea level in low pressure, which
  // would otherwise produce a negative elevation angle.
  const altKm = Math.max(0, ac.altitude ?? 0) * FT_TO_KM;
  const elevationDeg = groundKm === 0 ? 90 : deg(Math.atan2(altKm, groundKm));
  const slantKm = Math.hypot(groundKm, altKm);
  const bearing = bearingDeg(observer.lat, observer.lon, ac.lat, ac.lon);

  return {
    ...ac,
    groundKm,
    slantKm,
    elevationDeg,
    bearingDeg: bearing,
    lookDirection: compass(bearing),
    overhead: elevationDeg >= 60,
    // An airliner ~40 m long stops being resolvable to the naked eye somewhere
    // past ~50 km slant range in clear air.
    nakedEyePlausible: slantKm <= 50,
    cpa: closestApproach(observer, ac),
  };
}

/** Rank by what a person actually cares about: what's about to be overhead. */
export function rank(a, b) {
  const score = (x) => {
    if (x.overhead) return 0;                                   // overhead right now
    if (x.cpa?.approaching && x.cpa.elevationDeg >= 40) return 1 + x.cpa.secondsAway / 10000;
    return 2 + (90 - x.elevationDeg) / 90;
  };
  return score(a) - score(b);
}

// ── CLI demo ──────────────────────────────────────────────────────────────────

async function main() {
  const lat = Number(process.argv[2]);
  const lon = Number(process.argv[3]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    console.error("usage: node overhead.mjs <lat> <lon>");
    process.exit(1);
  }
  const observer = { lat, lon };

  const [acRes, wxRes] = await Promise.all([
    fetch(`https://api.adsb.lol/v2/point/${lat}/${lon}/60`, {
      headers: { "user-agent": "SkyGlance-reference/0.1 (+https://github.com/darshjoshi/skyglance-mac)" },
    }).then((r) => r.json()),
    fetch(`https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
          `&current=cloud_cover,visibility,is_day`).then((r) => r.json()).catch(() => null),
  ]);

  const aircraft = (acRes.ac ?? [])
    .filter((a) => a.lat != null && a.lon != null)
    .map((a) => ({
      hex: a.hex,
      callsign: a.flight?.trim() || null,
      registration: a.r?.trim() || null,
      type: a.t?.trim() || null,
      lat: a.lat,
      lon: a.lon,
      altitude: a.alt_baro === "ground" ? 0 : a.alt_baro,
      onGround: a.alt_baro === "ground",
      groundSpeed: a.gs ?? null,
      track: a.track ?? null,
      verticalRate: a.baro_rate ?? null,
    }))
    .filter((a) => !a.onGround)
    .map((a) => describe(observer, a))
    .sort(rank);

  const wx = wxRes?.current;
  if (wx) {
    const seeing = wx.cloud_cover > 80 ? "overcast — you probably won't see anything"
      : wx.cloud_cover > 40 ? "broken cloud — hit and miss"
      : "clear enough to spot aircraft";
    console.log(`\nConditions: ${wx.cloud_cover}% cloud, ${(wx.visibility / 1000).toFixed(0)} km visibility, ` +
                `${wx.is_day ? "daylight" : "dark"} — ${seeing}`);
  }

  console.log(`\n${aircraft.length} aircraft airborne within 60 nm of ${lat}, ${lon}\n`);
  console.log("  OVERHEAD NOW (elevation ≥ 60°)");
  const now = aircraft.filter((a) => a.overhead);
  if (!now.length) console.log("    — nothing directly overhead —");
  for (const a of now) {
    console.log(`    ${(a.callsign ?? a.hex).padEnd(9)} ${String(a.type ?? "?").padEnd(5)} ` +
      `${String(Math.round(a.altitude)).padStart(6)} ft  ${a.elevationDeg.toFixed(0)}° up  ` +
      `look ${a.lookDirection}`);
  }

  console.log("\n  COMING OVERHEAD (closest approach ≥ 40° elevation, still inbound)");
  const soon = aircraft.filter((a) => !a.overhead && a.cpa?.approaching && a.cpa.elevationDeg >= 40)
                       .sort((x, y) => x.cpa.secondsAway - y.cpa.secondsAway).slice(0, 8);
  if (!soon.length) console.log("    — nothing inbound —");
  for (const a of soon) {
    const m = Math.floor(a.cpa.secondsAway / 60), s = Math.round(a.cpa.secondsAway % 60);
    console.log(`    ${(a.callsign ?? a.hex).padEnd(9)} ${String(a.type ?? "?").padEnd(5)} ` +
      `in ${String(m).padStart(2)}m${String(s).padStart(2)}s  ` +
      `passing ${a.cpa.groundKm.toFixed(1)} km ${compass(a.cpa.bearingDeg)}  ` +
      `at ${a.cpa.altitudeFt.toLocaleString()} ft  ${a.cpa.elevationDeg.toFixed(0)}° up`);
  }

  console.log("\n  NEAREST RIGHT NOW");
  for (const a of [...aircraft].sort((x, y) => x.slantKm - y.slantKm).slice(0, 5)) {
    console.log(`    ${(a.callsign ?? a.hex).padEnd(9)} ${String(a.type ?? "?").padEnd(5)} ` +
      `${a.slantKm.toFixed(1).padStart(5)} km away  ${a.elevationDeg.toFixed(0).padStart(2)}° up  ` +
      `${a.lookDirection.padEnd(3)}  ${a.nakedEyePlausible ? "visible" : "too far"}`);
  }
  console.log();
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
