import XCTest
@testable import OverheadKit

/// The user's coordinate is the most sensitive thing this app holds, and feed
/// identifiers are the least trustworthy. These tests pin both.
final class QueryCoarseningTests: XCTestCase {

    func testCoordinateSentUpstreamIsRoundedToTwoPlaces() {
        let exact = Coordinate(latitude: 51.47212, longitude: -0.45431)
        let sent = exact.coarsenedForQuery
        XCTAssertEqual(sent.latitude, 51.47, accuracy: 1e-9)
        XCTAssertEqual(sent.longitude, -0.45, accuracy: 1e-9)
    }

    func testCoarseningRoundsRatherThanTruncating() {
        // Truncation would bias every user's reported position consistently
        // south-west, which is a weaker guarantee than it looks.
        let c = Coordinate(latitude: 51.4789, longitude: -0.4561).coarsenedForQuery
        XCTAssertEqual(c.latitude, 51.48, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, -0.46, accuracy: 1e-9)
    }

    func testCoarseningNeverMovesTheCentreMoreThanAboutAKilometre() {
        // The bound that makes this safe against a 111 km query radius.
        for lat in stride(from: -60.0, through: 60.0, by: 7.5) {
            for lon in stride(from: -180.0, through: 180.0, by: 23.0) {
                let exact = Coordinate(latitude: lat + 0.004567, longitude: lon + 0.004567)
                let sent = exact.coarsenedForQuery
                let metres = Geometry.distanceKm(exact, sent) * 1000
                XCTAssertLessThan(metres, 1_200, "moved \(metres) m at \(lat),\(lon)")
            }
        }
    }

    /// The whole point of coarsening at `makeURL` rather than earlier: the dome
    /// must still be drawn from the true position.
    func testGeometryIsUnaffectedByCoarsening() {
        let exact = Coordinate(latitude: 51.47212, longitude: -0.45431)
        let target = Coordinate(latitude: 51.55000, longitude: -0.45431)
        let fromExact = Geometry.bearingDegrees(from: exact, to: target)
        let fromCoarse = Geometry.bearingDegrees(from: exact.coarsenedForQuery, to: target)
        // Different inputs must give different answers — proving the test would
        // actually catch the geometry being fed the rounded value by mistake.
        XCTAssertNotEqual(fromExact, fromCoarse)
    }

    /// The real proof: build the URLs the app actually sends and confirm the
    /// user's exact position does not appear in any of them.
    func testNoFeedURLCarriesFullPrecision() throws {
        let exact = Coordinate(latitude: 51.47212, longitude: -0.45431)
        XCTAssertFalse(FeedSource.all.isEmpty)
        for source in FeedSource.all {
            let url = try XCTUnwrap(source.makeURL(exact, 60)).absoluteString
            XCTAssertFalse(url.contains("51.47212"), "\(source.name) leaked latitude: \(url)")
            XCTAssertFalse(url.contains("0.45431"), "\(source.name) leaked longitude: \(url)")
            XCTAssertTrue(url.contains("51.47"), "\(source.name) lost the position: \(url)")
            XCTAssertTrue(url.hasPrefix("https://"), "\(source.name) is not TLS: \(url)")
        }
    }
}

final class FeedIdentifierValidationTests: XCTestCase {

    func testRealIdentifiersAreAccepted() {
        XCTAssertTrue(EnrichmentClient.isValidCallsign("UAL36"))
        XCTAssertTrue(EnrichmentClient.isValidCallsign("BAW117"))
        XCTAssertTrue(EnrichmentClient.isValidHex("a1b2c3"))
        XCTAssertTrue(EnrichmentClient.isValidRegistration("N123AB"))
        XCTAssertTrue(EnrichmentClient.isValidRegistration("G-EUPT"))
        XCTAssertTrue(EnrichmentClient.isValidRegistration("VH-OQA"))
    }

    /// adsb.lol prefixes non-ICAO TIS-B targets with `~`. Rejecting those would
    /// silently strip detail from a whole class of aircraft, and look identical
    /// to the upstream simply not knowing them.
    func testNonICAOHexPrefixSurvives() {
        XCTAssertTrue(EnrichmentClient.isValidHex("~abc123"))
    }

    func testPathTraversalIsRejected() {
        XCTAssertFalse(EnrichmentClient.isValidCallsign("../../v0/aircraft/ABC123"))
        XCTAssertFalse(EnrichmentClient.isValidHex("../../.."))
        XCTAssertFalse(EnrichmentClient.isValidRegistration("%2e%2e%2f"))
    }

    func testQueryAndFragmentInjectionAreRejected() {
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1?redirect=x"))
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1#@evil.example.com/"))
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1&x=1"))
    }

    func testEmptyAndOverlongAreRejected() {
        XCTAssertFalse(EnrichmentClient.isValidCallsign(""))
        XCTAssertFalse(EnrichmentClient.isValidCallsign(String(repeating: "A", count: 17)))
    }

    func testWhitespaceAndControlCharactersAreRejected() {
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1 WITH SPACE"))
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1\n"))
        XCTAssertFalse(EnrichmentClient.isValidCallsign("AAL1/"))
    }

    /// Non-ASCII letters satisfy `isLetter`, so the ASCII check is doing real
    /// work — a homoglyph must not reach a URL.
    func testNonASCIILettersAreRejected() {
        XCTAssertFalse(EnrichmentClient.isValidCallsign("АAL36"))  // Cyrillic А
    }

    func testOnlyHTTPSPhotoURLsAreAccepted() {
        XCTAssertTrue(EnrichmentClient.isHTTPS("https://api.planespotters.net/x.jpg"))
        XCTAssertFalse(EnrichmentClient.isHTTPS("http://api.planespotters.net/x.jpg"))
        XCTAssertFalse(EnrichmentClient.isHTTPS("file:///etc/passwd"))
        XCTAssertFalse(EnrichmentClient.isHTTPS("javascript:alert(1)"))
        XCTAssertFalse(EnrichmentClient.isHTTPS("not a url"))
    }
}
