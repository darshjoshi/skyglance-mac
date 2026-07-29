import XCTest
@testable import OverheadKit

/// The one thing every user has to type. If this is wrong, nobody gets past the
/// first screen.
final class LocationInputTests: XCTestCase {

    private func coordinate(_ text: String) -> Coordinate? {
        if case .success(let c) = LocationInput.parse(text) { return c }
        return nil
    }

    private func problem(_ text: String) -> LocationInput.Problem? {
        if case .failure(let p) = LocationInput.parse(text) { return p }
        return nil
    }

    func testPlainDecimalPair() {
        let c = coordinate("51.47, -0.4543")
        XCTAssertEqual(c?.latitude, 51.47)
        XCTAssertEqual(c?.longitude, -0.4543)
    }

    /// The shapes people actually paste, rather than the one shape we asked for.
    func testToleratesRealWorldPastes() {
        let expected = Coordinate(latitude: 51.47, longitude: -0.4543)
        for text in ["51.47,-0.4543",
                     "  51.47 ,  -0.4543  ",
                     "51.47 -0.4543",
                     "51.47°, -0.4543°",
                     "51.47°  -0.4543°"] {
            XCTAssertEqual(coordinate(text), expected, "failed on \(text.debugDescription)")
        }
    }

    func testOurOwnPlaceholderParses() {
        XCTAssertNotNil(coordinate(LocationInput.example),
                        "the example we show must itself be valid input")
    }

    func testRoundTripsThroughFormat() {
        let original = Coordinate(latitude: -33.86882, longitude: 151.20929)
        let reparsed = coordinate(LocationInput.format(original))
        XCTAssertEqual(reparsed?.latitude ?? 0, original.latitude, accuracy: 0.00001)
        XCTAssertEqual(reparsed?.longitude ?? 0, original.longitude, accuracy: 0.00001)
    }

    func testRejectsWithASpecificReason() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        XCTAssertEqual(problem("London"), .notTwoNumbers)
        XCTAssertEqual(problem("51.47"), .notTwoNumbers)
        XCTAssertEqual(problem("51.47, -0.45, 12"), .notTwoNumbers)
        XCTAssertEqual(problem("91, 0"), .latitudeOutOfRange)
        XCTAssertEqual(problem("0, 181"), .longitudeOutOfRange)
    }

    /// Every rejection has to say something a person can act on.
    func testEveryProblemHasAUsefulMessage() {
        for p: LocationInput.Problem in [.empty, .notTwoNumbers,
                                        .latitudeOutOfRange, .longitudeOutOfRange] {
            XCTAssertFalse(p.message.isEmpty)
            XCTAssertTrue(p.message.count > 15, "\(p) message is too terse to help")
        }
    }

    /// 0,0 is a real place in the Gulf of Guinea. It must parse, because the app
    /// distinguishes "never configured" by the absence of the key, not by 0,0.
    func testNullIslandIsAValidLocation() {
        XCTAssertEqual(coordinate("0, 0"), Coordinate(latitude: 0, longitude: 0))
    }

    func testAcceptsTheExtremes() {
        XCTAssertEqual(coordinate("90, 180"), Coordinate(latitude: 90, longitude: 180))
        XCTAssertEqual(coordinate("-90, -180"), Coordinate(latitude: -90, longitude: -180))
    }
}
