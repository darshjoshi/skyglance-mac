import Foundation

public struct Coordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geometry {
    static let earthRadiusKm = 6371.0
    static let feetToKm = 0.0003048
    static let knotsToKmPerSecond = 0.000514444
    static let kmPerDegreeLatitude = 111.195

    @inlinable static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inlinable static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    public static func distanceKm(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = radians(b.latitude - a.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let h = pow(sin(dLat / 2), 2)
            + cos(radians(a.latitude)) * cos(radians(b.latitude)) * pow(sin(dLon / 2), 2)
        return 2 * earthRadiusKm * asin(min(1, sqrt(h)))
    }

    /// Compass bearing from `a` to `b`, 0 = north, 90 = east.
    public static func bearingDegrees(from a: Coordinate, to b: Coordinate) -> Double {
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(radians(b.latitude))
        let x = cos(radians(a.latitude)) * sin(radians(b.latitude))
            - sin(radians(a.latitude)) * cos(radians(b.latitude)) * cos(dLon)
        return (degrees(atan2(y, x)) + 360).truncatingRemainder(dividingBy: 360)
    }

    static let compassPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    public static func compassPoint(_ bearing: Double) -> String {
        compassPoints[Int((bearing / 22.5).rounded()) % 16]
    }
}

/// Where an aircraft will be at its closest approach, assuming it holds its
/// current heading. Only trustworthy for about 60 seconds — see OVER-MY-HOUSE.md.
public struct ClosestApproach: Sendable {
    public let secondsAway: Double
    public let groundDistanceKm: Double
    public let altitudeFeet: Double
    public let elevationDegrees: Double
    public let bearingDegrees: Double
    public var isApproaching: Bool { secondsAway > 0 }
}

public struct Sighting: Identifiable, Sendable {
    public let id: String            // ICAO 24-bit hex — the only stable identity
    public let callsign: String?
    public let registration: String?
    public let typeCode: String?
    public let description: String?
    public let coordinate: Coordinate
    public let altitudeFeet: Double
    public let groundSpeedKnots: Double?
    public let trackDegrees: Double?

    public let groundDistanceKm: Double
    public let slantRangeKm: Double
    public let elevationDegrees: Double
    public let bearingDegrees: Double
    public let closestApproach: ClosestApproach?
    public let sources: [String]
    public let category: String?
    public let isMilitary: Bool
    public let hasEmergency: Bool

    /// ADS-B emitter category A3/A4/A5 — airliner-sized or bigger.
    public var isLarge: Bool { ["A3", "A4", "A5"].contains(category ?? "") }
    public var isRotorcraft: Bool { category == "A7" }

    public var label: String { callsign ?? registration ?? id.uppercased() }
    public var lookDirection: String { Geometry.compassPoint(bearingDegrees) }
    /// Steep enough that you'd have to properly crane your neck.
    public var isOverhead: Bool { elevationDegrees >= 60 }
    /// An airliner stops being resolvable to the naked eye past roughly this range.
    public var isPlausiblyVisible: Bool { slantRangeKm <= 50 }
}

extension Sighting {
    public init?(aircraft a: Aircraft, observer: Coordinate, sources: [String]) {
        guard let coordinate = a.coordinate else { return nil }
        // alt_baro can read slightly negative near sea level in low pressure,
        // which would otherwise yield a negative elevation angle.
        let altitudeFeet = max(0, a.altitudeFeet ?? 0)
        let groundKm = Geometry.distanceKm(observer, coordinate)
        let altitudeKm = altitudeFeet * Geometry.feetToKm

        self.id = a.hex
        self.callsign = a.callsign
        self.registration = a.registration
        self.typeCode = a.typeCode
        self.description = a.description
        self.coordinate = coordinate
        self.altitudeFeet = altitudeFeet
        self.groundSpeedKnots = a.groundSpeedKnots
        self.trackDegrees = a.trackDegrees
        self.groundDistanceKm = groundKm
        self.slantRangeKm = (groundKm * groundKm + altitudeKm * altitudeKm).squareRoot()
        self.elevationDegrees = groundKm == 0 ? 90 : Geometry.degrees(atan2(altitudeKm, groundKm))
        self.bearingDegrees = Geometry.bearingDegrees(from: observer, to: coordinate)
        self.sources = sources
        self.category = a.category
        self.isMilitary = a.isMilitary
        self.hasEmergency = a.hasEmergency
        self.closestApproach = Sighting.closestApproach(
            observer: observer, coordinate: coordinate, altitudeFeet: altitudeFeet,
            groundSpeedKnots: a.groundSpeedKnots, trackDegrees: a.trackDegrees,
            verticalRateFeetPerMinute: a.verticalRateFeetPerMinute)
    }

    /// Minimise |p + v·t| in a local flat frame. Good to well under a percent inside ~100 km.
    static func closestApproach(observer: Coordinate, coordinate: Coordinate,
                                altitudeFeet: Double, groundSpeedKnots: Double?,
                                trackDegrees: Double?,
                                verticalRateFeetPerMinute: Double?) -> ClosestApproach? {
        guard let speed = groundSpeedKnots, let track = trackDegrees, speed > 0 else { return nil }

        let east = (coordinate.longitude - observer.longitude)
            * Geometry.kmPerDegreeLatitude * cos(Geometry.radians(observer.latitude))
        let north = (coordinate.latitude - observer.latitude) * Geometry.kmPerDegreeLatitude

        let vEast = speed * Geometry.knotsToKmPerSecond * sin(Geometry.radians(track))
        let vNorth = speed * Geometry.knotsToKmPerSecond * cos(Geometry.radians(track))
        let speedSquared = vEast * vEast + vNorth * vNorth
        guard speedSquared > 0 else { return nil }

        let t = -(east * vEast + north * vNorth) / speedSquared
        let closestEast = east + vEast * t
        let closestNorth = north + vNorth * t
        let ground = (closestEast * closestEast + closestNorth * closestNorth).squareRoot()
        let altitude = max(0, altitudeFeet + ((verticalRateFeetPerMinute ?? 0) / 60) * t)

        return ClosestApproach(
            secondsAway: t,
            groundDistanceKm: ground,
            altitudeFeet: altitude,
            elevationDegrees: ground == 0 ? 90
                : Geometry.degrees(atan2(altitude * Geometry.feetToKm, ground)),
            bearingDegrees: (Geometry.degrees(atan2(closestEast, closestNorth)) + 360)
                .truncatingRemainder(dividingBy: 360))
    }
}
