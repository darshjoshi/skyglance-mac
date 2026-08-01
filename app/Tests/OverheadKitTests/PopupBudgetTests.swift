import XCTest
@testable import OverheadKit

/// Popups get their own budget, and the two channels must not spend each
/// other's. These pin that, plus the placement maths the card depends on.
final class PopupBudgetTests: XCTestCase {

    private let observer = Coordinate(latitude: 51.47, longitude: -0.4543)

    /// A large aircraft low and close — clears the bar in both policies.
    /// Built from wire JSON like the other fixtures, so it exercises the same
    /// decoding path a real sighting does.
    private func interestingSighting(id: String) -> Sighting {
        let lat = observer.latitude + 1.5 / 111.195
        let json = """
        {"hex":"\(id)","lat":\(lat),"lon":\(observer.longitude),"alt_baro":2200,
         "category":"A5","t":"B748","gs":180,"track":90}
        """
        let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
        return Sighting(aircraft: aircraft, observer: observer, sources: ["test"])!
    }

    private var popupPolicy: AlertPolicy {
        AlertPolicy(maximumPerDay: 20, minimumGap: 5 * 60, requireDaylight: false,
                    perCategoryDailyCap: [.emergency: Int.max, .rare: 10, .military: 8,
                                          .bigAndLow: 8, .rotorcraft: 5])
    }

    private var notificationPolicy: AlertPolicy {
        AlertPolicy(requireDaylight: false)
    }

    /// The whole point of a second governor: spending the popup budget must not
    /// consume the notification budget, so an evening away still gets alerts.
    func testBudgetsAreIndependent() throws {
        let popupGovernor = AlertGovernor()
        let notificationGovernor = AlertGovernor()
        let scorer = InterestScorer()
        var now = Date()

        var popupsFired = 0
        for i in 0..<6 {
            let s = interestingSighting(id: String(format: "aa00%02d", i))
            guard let interest = scorer.score(s) else { continue }
            let d = popupGovernor.evaluate(s, interest: interest, policy: popupPolicy,
                                           conditions: nil, now: now)
            if d.shouldAlert {
                popupGovernor.record(s, interest: interest)
                popupsFired += 1
            }
            now += 6 * 60   // clear the popup gap, not the notification gap
        }
        XCTAssertGreaterThan(popupsFired, 1, "the looser gap should allow several")
        XCTAssertEqual(notificationGovernor.sentTodayCount, 0,
                       "popups must not spend the notification budget")
    }

    /// The looser gap is the reason popups exist as a separate channel.
    func testPopupGapIsShorterThanNotificationGap() throws {
        let scorer = InterestScorer()
        let first = interestingSighting(id: "aa1001")
        let second = interestingSighting(id: "aa1002")
        let start = Date()
        let sixMinutesLater = start + 6 * 60

        let popupGovernor = AlertGovernor()
        let interest = try XCTUnwrap(scorer.score(first))
        XCTAssertTrue(popupGovernor.evaluate(first, interest: interest, policy: popupPolicy,
                                             conditions: nil, now: start).shouldAlert)
        popupGovernor.record(first, interest: interest)

        let i2 = try XCTUnwrap(scorer.score(second))
        XCTAssertTrue(popupGovernor.evaluate(second, interest: i2, policy: popupPolicy,
                                             conditions: nil, now: sixMinutesLater).shouldAlert,
                      "6 minutes clears the 5-minute popup gap")

        let notificationGovernor = AlertGovernor()
        XCTAssertTrue(notificationGovernor.evaluate(first, interest: interest,
                                                    policy: notificationPolicy,
                                                    conditions: nil, now: start).shouldAlert)
        notificationGovernor.record(first, interest: interest)
        XCTAssertFalse(notificationGovernor.evaluate(second, interest: i2,
                                                     policy: notificationPolicy,
                                                     conditions: nil,
                                                     now: sixMinutesLater).shouldAlert,
                       "6 minutes does not clear the 20-minute notification gap")
    }

    /// An emergency is never rate-limited in either channel.
    func testEmergencyIsUncappedInThePopupPolicy() {
        XCTAssertEqual(popupPolicy.perCategoryDailyCap[.emergency], Int.max)
    }

    func testPopupPolicyIsMoreGenerousButStillBounded() {
        XCTAssertGreaterThan(popupPolicy.maximumPerDay, notificationPolicy.maximumPerDay)
        XCTAssertLessThan(popupPolicy.minimumGap, notificationPolicy.minimumGap)
        // Bounded is the point — an unbounded popup is a popup you switch off.
        XCTAssertLessThanOrEqual(popupPolicy.maximumPerDay, 30)
    }
}
