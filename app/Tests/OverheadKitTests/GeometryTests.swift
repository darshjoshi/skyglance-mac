import XCTest
@testable import OverheadKit

final class GeometryTests: XCTestCase {
    let observer = Coordinate(latitude: 51.0, longitude: 0.0)
    let kmPerDegreeLatitude = 111.195

    /// Build a Sighting directly from synthetic values, bypassing the wire format.
    private func sighting(northKm: Double = 0, eastKm: Double = 0, altitudeFeet: Double,
                          speedKnots: Double? = nil, trackDegrees: Double? = nil,
                          verticalRate: Double? = nil) -> Sighting {
        let lat = observer.latitude + northKm / kmPerDegreeLatitude
        let lon = observer.longitude
            + eastKm / (kmPerDegreeLatitude * cos(observer.latitude * .pi / 180))
        let json = """
        {"hex":"abc123","lat":\(lat),"lon":\(lon),"alt_baro":\(altitudeFeet)
        \(speedKnots.map { ",\"gs\":\($0)" } ?? "")
        \(trackDegrees.map { ",\"track\":\($0)" } ?? "")
        \(verticalRate.map { ",\"baro_rate\":\($0)" } ?? "")}
        """
        let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        return Sighting(aircraft: aircraft, observer: observer, sources: ["test"])!
    }

    func testElevationAt45Degrees() {
        // 1 km out, 1 km up (3280.84 ft)
        let s = sighting(northKm: 1, altitudeFeet: 3280.84)
        XCTAssertEqual(s.elevationDegrees, 45, accuracy: 0.2)
        XCTAssertEqual(s.bearingDegrees, 0, accuracy: 0.5)
        XCTAssertEqual(s.slantRangeKm, 2.0.squareRoot(), accuracy: 0.02)
    }

    func testElevationDirectlyOverhead() {
        let s = sighting(altitudeFeet: 35000)
        XCTAssertEqual(s.elevationDegrees, 90, accuracy: 0.01)
        XCTAssertTrue(s.isOverhead)
    }

    func testShallowElevationAndEastBearing() {
        let s = sighting(eastKm: 10, altitudeFeet: 3280.84)
        XCTAssertEqual(s.elevationDegrees, 5.71, accuracy: 0.2)
        XCTAssertEqual(s.bearingDegrees, 90, accuracy: 0.6)
        XCTAssertFalse(s.isOverhead)
    }

    func testNegativeAltitudeClampsToZero() {
        // alt_baro can read slightly negative near sea level in low pressure.
        let s = sighting(northKm: 5, altitudeFeet: -75)
        XCTAssertEqual(s.altitudeFeet, 0)
        XCTAssertEqual(s.elevationDegrees, 0, accuracy: 0.001)
    }

    func testClosestApproachHeadOn() {
        // 10 km south, flying due north at 360 kt -> 54 s, passes directly overhead
        let s = sighting(northKm: -10, altitudeFeet: 10000, speedKnots: 360, trackDegrees: 0)
        let cpa = try! XCTUnwrap(s.closestApproach)
        XCTAssertEqual(cpa.secondsAway, 54.0, accuracy: 1.5)
        XCTAssertEqual(cpa.groundDistanceKm, 0, accuracy: 0.1)
        XCTAssertTrue(cpa.isApproaching)
    }

    func testClosestApproachPerpendicularIsNow() {
        // Flying due east from 10 km south: never gets closer.
        let s = sighting(northKm: -10, altitudeFeet: 10000, speedKnots: 360, trackDegrees: 90)
        let cpa = try! XCTUnwrap(s.closestApproach)
        XCTAssertEqual(cpa.secondsAway, 0, accuracy: 0.5)
        XCTAssertEqual(cpa.groundDistanceKm, 10, accuracy: 0.2)
    }

    func testClosestApproachAccountsForDescent() {
        // 54 s at -2000 ft/min loses about 1800 ft.
        let s = sighting(northKm: -10, altitudeFeet: 10000, speedKnots: 360,
                         trackDegrees: 0, verticalRate: -2000)
        let cpa = try! XCTUnwrap(s.closestApproach)
        XCTAssertEqual(cpa.altitudeFeet, 10000 - 2000 * (54.0 / 60), accuracy: 60)
    }

    func testCompassPoints() {
        XCTAssertEqual(Geometry.compassPoint(0), "N")
        XCTAssertEqual(Geometry.compassPoint(90), "E")
        XCTAssertEqual(Geometry.compassPoint(180), "S")
        XCTAssertEqual(Geometry.compassPoint(225), "SW")
        XCTAssertEqual(Geometry.compassPoint(359), "N")
    }
}

final class WireFormatTests: XCTestCase {
    /// The single most common ADS-B parsing bug: alt_baro is a Double in flight
    /// but the string "ground" on the ground.
    func testGroundAltitudeDecodesAsString() throws {
        let json = #"{"hex":"a1","lat":1.0,"lon":2.0,"alt_baro":"ground"}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertTrue(a.isOnGround)
        XCTAssertEqual(a.altitudeFeet, 0)
    }

    func testNumericAltitudeDecodes() throws {
        let json = #"{"hex":"a1","lat":1.0,"lon":2.0,"alt_baro":37000}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertFalse(a.isOnGround)
        XCTAssertEqual(a.altitudeFeet, 37000)
    }

    func testCallsignPaddingIsTrimmed() throws {
        let json = #"{"hex":"a1","flight":"BAW117  ","lat":1.0,"lon":2.0,"alt_baro":100}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertEqual(a.callsign, "BAW117")
    }

    func testEmptyCallsignBecomesNil() throws {
        let json = #"{"hex":"a1","flight":"        ","lat":1.0,"lon":2.0,"alt_baro":100}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertNil(a.callsign)
    }

    func testMilitaryFlag() throws {
        let json = #"{"hex":"a1","lat":1.0,"lon":2.0,"alt_baro":100,"dbFlags":1}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertTrue(a.isMilitary)
    }

    func testEmergencySquawkDetected() throws {
        let json = #"{"hex":"a1","lat":1.0,"lon":2.0,"alt_baro":100,"squawk":"7700","emergency":"none"}"#
        let a = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        XCTAssertTrue(a.hasEmergency)
    }
}

final class SkyStateTests: XCTestCase {
    /// Predictions beyond the trusted window must never reach the UI.
    func testInboundExcludesUntrustworthyHorizon() throws {
        let observer = Coordinate(latitude: 51, longitude: 0)
        // 60 km south at 360 kt is roughly 324 s away — well past the 90 s window.
        let far = #"{"hex":"far","lat":50.4605,"lon":0.0,"alt_baro":30000,"gs":360,"track":0}"#
        // 5 km south at 3,000 ft: only 10° up now, so not yet "overhead", but it
        // passes directly over in about 27 s.
        let near = #"{"hex":"near","lat":50.9550,"lon":0.0,"alt_baro":3000,"gs":360,"track":0}"#
        // 5 km south at 30,000 ft is already 61° up — belongs in overheadNow, not inbound.
        let already = #"{"hex":"already","lat":50.9550,"lon":0.0,"alt_baro":30000,"gs":360,"track":0}"#

        let aircraft = try [far, near, already].map {
            try JSONDecoder().decode(Aircraft.self, from: Data($0.utf8))
        }
        let sightings = aircraft.compactMap { Sighting(aircraft: $0, observer: observer, sources: ["t"]) }
        let snapshot = Snapshot(sightings: sightings, capturedAt: Date(),
                                contributingSources: ["t"], isDegraded: false,
                                isStale: false, error: nil)
        let state = SkyState(snapshot: snapshot)

        XCTAssertFalse(state.inboundSoon.contains { $0.id == "far" },
                       "aircraft beyond the trusted window must not be shown as inbound")
        XCTAssertTrue(state.inboundSoon.contains { $0.id == "near" },
                      "an aircraft passing overhead within 90s must be shown as inbound")
        XCTAssertTrue(state.overheadNow.contains { $0.id == "already" },
                      "an aircraft already at 61° belongs in overheadNow, not inbound")
        XCTAssertFalse(state.inboundSoon.contains { $0.id == "already" },
                       "an aircraft already overhead must not be double-counted as inbound")
    }
}

final class DescriptionStyleTests: XCTestCase {
    /// Regression: an aircraft whose closest approach is at 0° elevation was
    /// rendering as "in 15s  0° up" inside the NEAREST list, which reads as an
    /// imminent flyover when it is actually landing at the horizon.
    func testProximityStyleNeverShowsCountdown() throws {
        let observer = Coordinate(latitude: 51, longitude: 0)
        // 3 km south at 500 ft, flying north: a real CPA exists and is imminent.
        let json = #"{"hex":"a1","flight":"BAW667","t":"A20N","lat":50.9730,"lon":0.0,"alt_baro":500,"gs":180,"track":0}"#
        let aircraft = try JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        let s = try XCTUnwrap(Sighting(aircraft: aircraft, observer: observer, sources: ["t"]))

        XCTAssertNotNil(s.closestApproach?.isApproaching)
        let proximity = s.describe(.proximity)
        XCTAssertFalse(proximity.contains("in "), "proximity rows must not show a countdown: \(proximity)")
        XCTAssertTrue(proximity.contains("km"), "proximity rows must show distance: \(proximity)")

        let approach = s.describe(.approach)
        XCTAssertTrue(approach.contains("in "), "approach rows should show a countdown: \(approach)")
    }
}
