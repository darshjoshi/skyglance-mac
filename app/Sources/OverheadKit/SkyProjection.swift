import Foundation

/// How the sky is flattened onto the dome, and how a position is carried forward
/// between polls. Both live here rather than in the view because both are pure
/// geometry that deserves a test, and the dome is the one part of the app whose
/// correctness cannot be checked by reading a string.
public enum SkyProjection {

    /// Measured over New York on 2026-07-29: 42 of 42 aircraft within 60 nm sat
    /// below 10° elevation (median 0.0°, p90 4.4°, max 9.7°). A linear
    /// elevation→radius mapping puts all of them in the outer 11% of the radius —
    /// 21% of the disc area — and leaves the rest permanently empty.
    ///
    /// This exponent redistributes that space toward the horizon, where the
    /// traffic actually is. Lower means more horizon stretch.
    public static let horizonBias = 0.35

    /// Where an elevation lands, as a fraction of the dome radius.
    /// 0 is the zenith, 1 is the horizon.
    public static func radiusFraction(elevationDegrees: Double) -> Double {
        let u = max(0, min(90, elevationDegrees)) / 90
        return 1 - pow(u, horizonBias)
    }

    /// Ring elevations chosen to be roughly evenly spaced *after* the bias is
    /// applied, rather than evenly spaced in degrees — otherwise the rings pile
    /// up in the same place the aircraft used to.
    public static let ringElevations: [Double] = [5, 15, 30, 60]
}

public extension Geometry {
    /// Carry a position forward along its current track.
    ///
    /// Used only to smooth the gap between three-second polls and to draw the
    /// short trail behind an aircraft — both well inside the ~90 s window where
    /// a straight-line assumption holds (see OVER-MY-HOUSE.md). Nothing here
    /// feeds a claim the user is asked to act on.
    static func advance(_ c: Coordinate, trackDegrees: Double,
                        groundSpeedKnots: Double, seconds: Double) -> Coordinate {
        let km = groundSpeedKnots * knotsToKmPerSecond * seconds
        guard km != 0 else { return c }
        let t = radians(trackDegrees)
        let cosLat = cos(radians(c.latitude))
        // At the poles a longitude step is meaningless; hold it rather than
        // dividing by ~zero and flinging the aircraft across the map.
        let dLon = abs(cosLat) < 1e-9 ? 0 : km * sin(t) / (kmPerDegreeLatitude * cosLat)
        return Coordinate(latitude: c.latitude + km * cos(t) / kmPerDegreeLatitude,
                          longitude: c.longitude + dLon)
    }
}

/// A direction to look, at a moment in time.
public struct SkyPoint: Sendable, Equatable {
    public let bearingDegrees: Double
    public let elevationDegrees: Double

    public init(bearingDegrees: Double, elevationDegrees: Double) {
        self.bearingDegrees = bearingDegrees
        self.elevationDegrees = elevationDegrees
    }
}

public extension Sighting {
    /// Where this aircraft appears `seconds` after it was observed. Negative
    /// values look backwards, which is how the trail is drawn.
    ///
    /// Falls back to the observed position whenever there is nothing to
    /// extrapolate from — a missing track must show a stationary aircraft, never
    /// one drifting north at zero knots.
    func skyPoint(from observer: Coordinate, after seconds: Double) -> SkyPoint {
        guard seconds != 0, let track = trackDegrees,
              let speed = groundSpeedKnots, speed > 0 else {
            return SkyPoint(bearingDegrees: bearingDegrees,
                            elevationDegrees: elevationDegrees)
        }
        let moved = Geometry.advance(coordinate, trackDegrees: track,
                                     groundSpeedKnots: speed, seconds: seconds)
        let ground = Geometry.distanceKm(observer, moved)
        let altitudeKm = max(0, altitudeFeet) * Geometry.feetToKm
        return SkyPoint(
            bearingDegrees: Geometry.bearingDegrees(from: observer, to: moved),
            // max(0,) because alt_baro reads slightly negative near sea level and
            // a -0° elevation renders outside the horizon ring.
            elevationDegrees: ground > 0
                ? max(0, Geometry.degrees(atan2(altitudeKm, ground)))
                : 90)
    }
}
