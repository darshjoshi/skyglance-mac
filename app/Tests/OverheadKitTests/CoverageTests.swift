import XCTest
@testable import OverheadKit
@testable import SkyGlance

/// The verdict setup shows before someone commits to a location.
///
/// Pulled out of the network call for the same reason `AlertRouting.prefersPopup`
/// was: getting it wrong is silent. The failure that motivated these tests looked
/// exactly like success — a snapshot with no error, full of aircraft, describing
/// somewhere the user was not asking about.
final class CoverageTests: XCTestCase {
    private func snapshot(sightings: Int, isStale: Bool = false,
                          isDegraded: Bool = false, error: String? = nil) -> Snapshot {
        Snapshot(sightings: Array(repeating: Self.sighting, count: sightings),
                 capturedAt: Date(), contributingSources: ["test"],
                 isDegraded: isDegraded, isStale: isStale, error: error)
    }

    func testAircraftPresentMeansLive() {
        XCTAssertEqual(SkyModel.Coverage.classify(snapshot(sightings: 12)), .live(12))
    }

    /// The case the whole feature exists for: receivers answered, and heard
    /// nothing. A 200 with an empty list is not a failure.
    func testAnsweredButEmptyMeansSilent() {
        XCTAssertEqual(SkyModel.Coverage.classify(snapshot(sightings: 0)), .silent)
    }

    func testErrorMeansUnreachableNotSilent() {
        XCTAssertEqual(
            SkyModel.Coverage.classify(snapshot(sightings: 0, error: "all sources unavailable")),
            .unreachable)
    }

    /// The bug this was written for. When every source fails, FeedClient hands
    /// back the last good snapshot — the saved location's sky — with no error on
    /// it. Reported as `.live` it would tell someone in an uncovered place that
    /// their sky is busy, using aircraft from a city they are not in.
    func testStaleFallbackIsUnreachableEvenThoughItCarriesAircraftAndNoError() {
        let staleFromSomewhereElse = snapshot(sightings: 85, isStale: true, error: nil)
        XCTAssertEqual(SkyModel.Coverage.classify(staleFromSomewhereElse), .unreachable)
    }

    /// The mirror of the above: a partial answer is still an answer about the
    /// right place. FeedClient only sets `isStale` on the fallback, and marks a
    /// one-source result `isDegraded` instead — so degraded must not be rejected,
    /// or a quiet-but-covered location would be told the feeds are down.
    func testDegradedButFreshIsStillAnAnswer() {
        XCTAssertEqual(SkyModel.Coverage.classify(snapshot(sightings: 3, isDegraded: true)),
                       .live(3))
        XCTAssertEqual(SkyModel.Coverage.classify(snapshot(sightings: 0, isDegraded: true)),
                       .silent)
    }

    private static let sighting: Sighting = {
        let json = """
        {"hex":"abc123","lat":51.6,"lon":0.0,"alt_baro":10000.0,"gs":250,"track":90}
        """
        let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        return Sighting(aircraft: aircraft,
                        observer: Coordinate(latitude: 51.5, longitude: 0.0),
                        sources: ["test"])!
    }()
}
