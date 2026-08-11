import XCTest
@testable import OverheadKit

/// The formatter is global state by design (see `Distance`), so every test here
/// restores it. A leaked unit would otherwise fail an unrelated test in whatever
/// order the suite happens to run.
final class UnitsTests: XCTestCase {
    private var original: DistanceUnit = .kilometres

    override func setUp() {
        super.setUp()
        original = Distance.unit
    }

    override func tearDown() {
        Distance.unit = original
        super.tearDown()
    }

    func testDefaultsToKilometresSoTestsDoNotDependOnRegion() {
        XCTAssertEqual(Distance.unit, .kilometres)
    }

    func testKilometresKeepOneDecimal() {
        Distance.unit = .kilometres
        XCTAssertEqual(Distance.format(kilometres: 12.34), "12.3 km")
    }

    func testMilesConvertRatherThanRelabel() {
        Distance.unit = .miles
        // 10 km is 6.2 miles. A relabelling bug would read "10.0 mi".
        XCTAssertEqual(Distance.format(kilometres: 10), "6.2 mi")
    }

    func testShortDistancesSurviveConversion() {
        Distance.unit = .miles
        // 0.6 km is the kind of reading an overhead alert carries; it must not
        // round away to "0.0 mi".
        XCTAssertEqual(Distance.format(kilometres: 0.6), "0.4 mi")
    }

    func testWholeUnitsRoundRatherThanTruncate() {
        Distance.unit = .kilometres
        XCTAssertEqual(Distance.formatWhole(kilometres: 40.7), "41 km")
        Distance.unit = .miles
        XCTAssertEqual(Distance.formatWhole(kilometres: 40.7), "25 mi")
    }

    /// The row text is built in OverheadKit rather than the view layer, so the
    /// preference has to reach it too — this is the string someone reads while
    /// actually looking at the sky.
    func testSightingDescriptionFollowsThePreference() {
        // 8 km north, 6 km up: a slant range of exactly 10 km.
        let observer = Coordinate(latitude: 51.0, longitude: 0.0)
        let lat = observer.latitude + 8 / 111.195
        let json = """
        {"hex":"abc123","lat":\(lat),"lon":0.0,"alt_baro":19685.0,"gs":250,"track":90}
        """
        let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        let sighting = Sighting(aircraft: aircraft, observer: observer, sources: ["test"])!
        XCTAssertEqual(sighting.slantRangeKm, 10, accuracy: 0.1)

        Distance.unit = .kilometres
        let metric = sighting.describe(.proximity)
        XCTAssertTrue(metric.contains("10.0 km"), metric)

        Distance.unit = .miles
        let imperial = sighting.describe(.proximity)
        XCTAssertTrue(imperial.contains("6.2 mi"), imperial)
        XCTAssertFalse(imperial.contains("km"), "no stray metric left behind: \(imperial)")
    }
}
