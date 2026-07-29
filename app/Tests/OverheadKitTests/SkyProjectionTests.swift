import XCTest
@testable import OverheadKit

final class SkyProjectionTests: XCTestCase {
    let observer = Coordinate(latitude: 51.47, longitude: -0.4543)
    let kmPerDegreeLatitude = 111.195

    private func sighting(northKm: Double = 0, eastKm: Double = 0, altitudeFeet: Double,
                          speedKnots: Double? = nil, trackDegrees: Double? = nil) -> Sighting {
        let lat = observer.latitude + northKm / kmPerDegreeLatitude
        let lon = observer.longitude
            + eastKm / (kmPerDegreeLatitude * cos(observer.latitude * .pi / 180))
        let json = """
        {"hex":"abc123","lat":\(lat),"lon":\(lon),"alt_baro":\(altitudeFeet)
        \(speedKnots.map { ",\"gs\":\($0)" } ?? "")
        \(trackDegrees.map { ",\"track\":\($0)" } ?? "")}
        """
        let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        return Sighting(aircraft: aircraft, observer: observer, sources: ["test"])!
    }

    // MARK: - Elevation → radius

    func testHorizonIsTheRimAndZenithIsTheCentre() {
        XCTAssertEqual(SkyProjection.radiusFraction(elevationDegrees: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(SkyProjection.radiusFraction(elevationDegrees: 90), 0.0, accuracy: 0.001)
    }

    func testHigherAlwaysMeansCloserToTheCentre() {
        var previous = SkyProjection.radiusFraction(elevationDegrees: 0)
        for elevation in stride(from: 1.0, through: 90.0, by: 1.0) {
            let r = SkyProjection.radiusFraction(elevationDegrees: elevation)
            XCTAssertLessThan(r, previous, "elevation \(elevation)° broke monotonicity")
            previous = r
        }
    }

    /// The whole reason this file exists. Every aircraft measured over the user's
    /// location sat below 10° elevation; a linear projection gave that band the
    /// outer 11% of the radius. If this regresses, the dome is unreadable again.
    func testHorizonBandGetsMostOfTheRadius() {
        let inner = SkyProjection.radiusFraction(elevationDegrees: 10)
        XCTAssertLessThan(inner, 0.6,
                          "0–10° must occupy at least 40% of the radius, got \(1 - inner)")
        XCTAssertGreaterThan(1 - inner, 0.4)

        // And it must beat the linear mapping it replaced, by a lot.
        let linear = 1.0 - (90.0 - 10.0) / 90.0
        XCTAssertGreaterThan(1 - inner, linear * 3)
    }

    func testOutOfRangeElevationsAreClamped() {
        // alt_baro noise produces small negative elevations; they must land on
        // the rim, not outside it.
        XCTAssertEqual(SkyProjection.radiusFraction(elevationDegrees: -3), 1.0, accuracy: 0.001)
        XCTAssertEqual(SkyProjection.radiusFraction(elevationDegrees: 400), 0.0, accuracy: 0.001)
    }

    func testRingsAreVisiblySeparated() {
        let radii = SkyProjection.ringElevations.map {
            SkyProjection.radiusFraction(elevationDegrees: $0)
        }
        for (a, b) in zip(radii, radii.dropFirst()) {
            XCTAssertGreaterThan(a - b, 0.08,
                                 "rings \(a) and \(b) are too close to tell apart")
        }
    }

    // MARK: - Dead reckoning

    func testNorthboundMovesNorth() {
        let start = Coordinate(latitude: 40.0, longitude: -74.0)
        // 600 kt for 60 s ≈ 18.52 km ≈ 0.1665° of latitude.
        let moved = Geometry.advance(start, trackDegrees: 0, groundSpeedKnots: 600, seconds: 60)
        XCTAssertEqual(moved.latitude - start.latitude, 0.1665, accuracy: 0.002)
        XCTAssertEqual(moved.longitude, start.longitude, accuracy: 1e-9)
    }

    func testEastboundMovesEastAndAccountsForLatitude() {
        let start = Coordinate(latitude: 60.0, longitude: 0.0)
        let moved = Geometry.advance(start, trackDegrees: 90, groundSpeedKnots: 600, seconds: 60)
        XCTAssertEqual(moved.latitude, start.latitude, accuracy: 1e-9)
        // At 60°N a degree of longitude is half as wide, so the step is doubled.
        XCTAssertEqual(moved.longitude, 0.333, accuracy: 0.005)
    }

    func testGoingBackwardsIsTheMirrorOfGoingForwards() {
        let start = Coordinate(latitude: 40.7, longitude: -74.0)
        let ahead = Geometry.advance(start, trackDegrees: 235, groundSpeedKnots: 420, seconds: 30)
        let behind = Geometry.advance(start, trackDegrees: 235, groundSpeedKnots: 420, seconds: -30)
        XCTAssertEqual(ahead.latitude - start.latitude,
                       start.latitude - behind.latitude, accuracy: 1e-9)
        XCTAssertEqual(ahead.longitude - start.longitude,
                       start.longitude - behind.longitude, accuracy: 1e-9)
    }

    func testStationaryAircraftDoesNotDrift() {
        let start = Coordinate(latitude: 40.7, longitude: -74.0)
        XCTAssertEqual(Geometry.advance(start, trackDegrees: 90,
                                        groundSpeedKnots: 0, seconds: 60), start)
    }

    // MARK: - Sky point

    func testZeroSecondsReproducesTheObservedPosition() {
        let s = sighting(northKm: 0, eastKm: 20, altitudeFeet: 10_000,
                         speedKnots: 400, trackDegrees: 270)
        let p = s.skyPoint(from: observer, after: 0)
        XCTAssertEqual(p.bearingDegrees, s.bearingDegrees, accuracy: 1e-9)
        XCTAssertEqual(p.elevationDegrees, s.elevationDegrees, accuracy: 1e-9)
    }

    /// A missing track is common on the ground and in some feeds. It must freeze
    /// the aircraft, not send it north at zero knots — a silently wrong trail is
    /// worse than no trail.
    func testMissingTrackOrSpeedFreezesTheAircraft() {
        for s in [sighting(eastKm: 20, altitudeFeet: 10_000, speedKnots: 400),
                  sighting(eastKm: 20, altitudeFeet: 10_000, trackDegrees: 270),
                  sighting(eastKm: 20, altitudeFeet: 10_000, speedKnots: 0, trackDegrees: 270)] {
            let p = s.skyPoint(from: observer, after: 30)
            XCTAssertEqual(p.bearingDegrees, s.bearingDegrees, accuracy: 1e-9)
            XCTAssertEqual(p.elevationDegrees, s.elevationDegrees, accuracy: 1e-9)
        }
    }

    /// An aircraft flying straight at you gets higher in the sky; that rise is the
    /// motion the dome is meant to show.
    func testInboundAircraftClimbsTheDome() {
        let s = sighting(eastKm: 20, altitudeFeet: 10_000, speedKnots: 400, trackDegrees: 270)
        let now = s.skyPoint(from: observer, after: 0)
        let soon = s.skyPoint(from: observer, after: 60)
        XCTAssertGreaterThan(soon.elevationDegrees, now.elevationDegrees)
        XCTAssertGreaterThan(SkyProjection.radiusFraction(elevationDegrees: now.elevationDegrees),
                             SkyProjection.radiusFraction(elevationDegrees: soon.elevationDegrees),
                             "it should be moving toward the centre of the dome")
    }

    func testElevationNeverGoesNegative() {
        // On the deck and receding fast — the geometry must still land on the rim.
        let s = sighting(eastKm: 2, altitudeFeet: 0, speedKnots: 300, trackDegrees: 90)
        XCTAssertGreaterThanOrEqual(s.skyPoint(from: observer, after: 60).elevationDegrees, 0)
    }
}
