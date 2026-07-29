import XCTest
@testable import OverheadKit

/// Fixtures captured from the live services. These shapes are the fragile part —
/// they are third-party, undocumented, and change without notice.
final class EnrichmentWireFormatTests: XCTestCase {

    func testADSBDBRouteDecodes() throws {
        let json = """
        {"response":{"flightroute":{"callsign":"UAL36","callsign_icao":"UAL36",
        "airline":{"name":"United Airlines","icao":"UAL","iata":"UA"},
        "origin":{"country_iso_name":"US","elevation":18,"iata_code":"EWR","icao_code":"KEWR",
        "latitude":40.6925,"longitude":-74.168701,"municipality":"Newark",
        "name":"Newark Liberty International Airport"},
        "destination":{"country_iso_name":"GB","elevation":135,"iata_code":"EDI","icao_code":"EGPH",
        "latitude":55.95,"longitude":-3.3725,"municipality":"Edinburgh","name":"Edinburgh Airport"}}}}
        """
        let decoded = try JSONDecoder().decode(ADSBDBRouteResponse.self, from: Data(json.utf8))
        let route = try XCTUnwrap(decoded.response.flightroute)
        XCTAssertEqual(route.airline?.name, "United Airlines")
        XCTAssertEqual(route.origin?.iata_code, "EWR")
        XCTAssertEqual(route.destination?.municipality, "Edinburgh")
    }

    /// adsbdb answers an unknown callsign with a *string* where the object goes.
    /// Decoding must fail softly rather than throw into the caller.
    func testADSBDBUnknownCallsignDoesNotCrash() {
        let json = #"{"response":"unknown callsign"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ADSBDBRouteResponse.self, from: Data(json.utf8)),
            "the shape genuinely differs; the client must treat this as a miss")
    }

    func testADSBDBAircraftDecodes() throws {
        let json = """
        {"response":{"aircraft":{"type":"737NG 823/W","icao_type":"B738","manufacturer":"Boeing",
        "mode_s":"ADD793","registration":"N991NN","registered_owner":"American Airlines",
        "registered_owner_country_name":"United States"}}}
        """
        let decoded = try JSONDecoder().decode(ADSBDBAircraftResponse.self, from: Data(json.utf8))
        let aircraft = try XCTUnwrap(decoded.response.aircraft)
        XCTAssertEqual(aircraft.registration, "N991NN")
        XCTAssertEqual(aircraft.registered_owner, "American Airlines")
        XCTAssertEqual(aircraft.type, "737NG 823/W")
    }

    /// hexdb capitalises its keys, and a Swift member cannot be named `Type`.
    func testHexDBAircraftMapsCapitalisedKeys() throws {
        let json = """
        {"ModeS":"A8FFC4","Registration":"N67919","Manufacturer":"Bell",
        "ICAOTypeCode":"B06","Type":"206B Jet Ranger","RegisteredOwners":"Private"}
        """
        let decoded = try JSONDecoder().decode(HexDBAircraft.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.registration, "N67919")
        XCTAssertEqual(decoded.typeName, "206B Jet Ranger")
        XCTAssertEqual(decoded.manufacturer, "Bell")
        XCTAssertEqual(decoded.owners, "Private")
    }

    func testHexDBRouteDecodes() throws {
        let json = #"{"flight":"BAW117","route":"EGLL-KJFK","updatetime":1333306563}"#
        let decoded = try JSONDecoder().decode(HexDBRoute.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.route, "EGLL-KJFK")
        let parts = try XCTUnwrap(decoded.route).split(separator: "-")
        XCTAssertEqual(parts.count, 2)
    }

    func testPlanespottersDecodes() throws {
        let json = """
        {"photos":[{"id":"1919621",
        "thumbnail":{"src":"https://t.plnspttrs.net/a_t.jpg","size":{"width":200,"height":133}},
        "thumbnail_large":{"src":"https://t.plnspttrs.net/a_280.jpg","size":{"width":419,"height":280}},
        "link":"https://www.planespotters.net/photo/1919621","photographer":"Yihao Qin"}]}
        """
        let decoded = try JSONDecoder().decode(PlanespottersResponse.self, from: Data(json.utf8))
        let photo = try XCTUnwrap(decoded.photos?.first)
        XCTAssertEqual(photo.photographer, "Yihao Qin")
        XCTAssertEqual(photo.thumbnail_large?.src, "https://t.plnspttrs.net/a_280.jpg")
    }

    func testPlanespottersEmptyResultIsNotAnError() throws {
        let decoded = try JSONDecoder().decode(PlanespottersResponse.self,
                                               from: Data(#"{"photos":[]}"#.utf8))
        XCTAssertNil(decoded.photos?.first)
    }
}

final class EnrichmentModelTests: XCTestCase {

    /// A 356pt panel cannot fit "Newark Liberty International Airport".
    func testAirportPrefersMunicipality() {
        let full = AirportRef(icao: "KEWR", iata: "EWR", name: "Newark Liberty International Airport",
                              municipality: "Newark")
        XCTAssertEqual(full.shortName, "Newark")
        XCTAssertEqual(full.code, "EWR")

        // hexdb only ever supplies an ICAO code.
        let sparse = AirportRef(icao: "EGLL", iata: nil)
        XCTAssertEqual(sparse.shortName, "EGLL")
        XCTAssertEqual(sparse.code, "EGLL")
    }

    /// Roughly 1 in 7 aircraft has no route; a half-route must never render as "? → ?".
    func testHalfRouteIsNotComplete() {
        let half = RouteInfo(airline: "United", origin: AirportRef(icao: "KEWR", iata: "EWR"),
                             destination: nil)
        XCTAssertFalse(half.isComplete)

        let whole = RouteInfo(airline: "United",
                              origin: AirportRef(icao: "KEWR", iata: "EWR"),
                              destination: AirportRef(icao: "EGPH", iata: "EDI"))
        XCTAssertTrue(whole.isComplete)
    }

    func testEmptyDetailIsDetectable() {
        XCTAssertTrue(AircraftDetail(hex: "abc123").isEmpty)
        XCTAssertFalse(AircraftDetail(hex: "abc123",
                                      photo: PhotoInfo(thumbnailURL: "u", link: "l",
                                                       photographer: "p")).isEmpty)
    }

    /// Negative results must persist, or an unknown callsign is re-requested on
    /// every single tap — these are volunteer-run services.
    func testCacheRoundTripsNegativeResults() throws {
        struct CacheFile: Codable {
            var aircraft: [String: AircraftInfo?]
            var routes: [String: RouteInfo?]
            var photos: [String: PhotoInfo?]
        }
        let original = CacheFile(aircraft: ["deadbe": nil],
                                 routes: ["ECJ80": nil],
                                 photos: ["N800MA": PhotoInfo(thumbnailURL: "u", link: "l",
                                                              photographer: "Keebird")])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CacheFile.self, from: data)

        XCTAssertTrue(restored.routes.keys.contains("ECJ80"),
                      "a known-miss must survive a restart so it is not re-fetched")
        XCTAssertEqual(restored.photos["N800MA"]??.photographer, "Keebird")
        XCTAssertTrue(restored.aircraft.keys.contains("deadbe"))
    }
}
