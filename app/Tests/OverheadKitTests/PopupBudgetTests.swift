import XCTest
@testable import OverheadKit

/// Two channels, two budgets, one memory of what already interrupted you.
/// Getting that split wrong is what produced duplicate alerts.
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

    /// The real policies, not hand-copied ones. A duplicate here drifted from
    /// production once already — it carried `requireDaylight: false` while the
    /// app ran with the default `true`.
    private let popupPolicy = AlertPolicy.popupDefaults
    private let notificationPolicy = AlertPolicy()

    // MARK: - Budgets stay separate

    func testPopupPolicyIsLooserThanTheNotificationPolicyButStillBounded() {
        XCTAssertGreaterThan(popupPolicy.maximumPerDay, notificationPolicy.maximumPerDay)
        XCTAssertLessThan(popupPolicy.minimumGap, notificationPolicy.minimumGap)
        XCTAssertLessThan(popupPolicy.minimumScore, notificationPolicy.minimumScore)
        // Still bounded. Tuned for "show me more", but a popup channel with no
        // ceiling at all is one you end up switching off.
        XCTAssertLessThanOrEqual(popupPolicy.maximumPerDay, 60)
        XCTAssertGreaterThanOrEqual(popupPolicy.minimumGap, 60)
        XCTAssertEqual(popupPolicy.perCategoryDailyCap[.emergency], Int.max)
    }

    /// The looser score threshold has to actually admit something the strict one
    /// rejects, or lowering it was pointless. A large aircraft low and close
    /// scores in `bigAndLow`'s 45–95 band; 70 took only the upper half.
    func testTheLowerScoreThresholdAdmitsMarginalTraffic() throws {
        let s = interestingSighting(id: "ff0001")
        let marginal = Interest(category: .bigAndLow, score: 60,
                                reason: "large aircraft low overhead")
        let governor = AlertGovernor()

        XCTAssertTrue(governor.evaluate(s, interest: marginal, policy: popupPolicy,
                                        conditions: nil).shouldAlert,
                      "a score of 60 should now earn a popup")
        XCTAssertFalse(AlertGovernor().evaluate(s, interest: marginal,
                                                policy: notificationPolicy,
                                                conditions: nil).shouldAlert,
                       "but must still not earn a notification")
    }

    /// Spending the popup budget must not spend the notification budget — this
    /// actually exercises both governors, unlike the version it replaces, which
    /// asserted a freshly-built governor's count was zero and so could not fail.
    func testSpendingThePopupBudgetDoesNotSpendTheNotificationBudget() throws {
        let dedupe = AlertGovernor.Dedupe()
        let popupGovernor = AlertGovernor(dedupe: dedupe)
        let notificationGovernor = AlertGovernor(dedupe: dedupe)
        let scorer = InterestScorer()
        var now = Date()

        for i in 0..<4 {
            let s = interestingSighting(id: String(format: "aa00%02d", i))
            let interest = try XCTUnwrap(scorer.score(s))
            let d = popupGovernor.evaluate(s, interest: interest, policy: popupPolicy,
                                           conditions: nil, now: now)
            if d.shouldAlert { popupGovernor.record(s, interest: interest, now: now) }
            now += 6 * 60   // clears the popup gap, not the notification gap
        }

        XCTAssertGreaterThan(popupGovernor.sentTodayCount, 1,
                             "the looser gap should admit several")
        XCTAssertEqual(notificationGovernor.sentTodayCount, 0,
                       "the notification budget must be untouched")

        // And the notification channel is still free to fire for a NEW aircraft.
        let fresh = interestingSighting(id: "bb0001")
        let interest = try XCTUnwrap(scorer.score(fresh))
        XCTAssertTrue(notificationGovernor.evaluate(fresh, interest: interest,
                                                    policy: notificationPolicy,
                                                    conditions: nil, now: now).shouldAlert)
    }

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
        popupGovernor.record(first, interest: interest, now: start)

        let i2 = try XCTUnwrap(scorer.score(second))
        XCTAssertTrue(popupGovernor.evaluate(second, interest: i2, policy: popupPolicy,
                                             conditions: nil, now: sixMinutesLater).shouldAlert,
                      "6 minutes clears the 5-minute popup gap")

        let notificationGovernor = AlertGovernor()
        XCTAssertTrue(notificationGovernor.evaluate(first, interest: interest,
                                                    policy: notificationPolicy,
                                                    conditions: nil, now: start).shouldAlert)
        notificationGovernor.record(first, interest: interest, now: start)
        XCTAssertFalse(notificationGovernor.evaluate(second, interest: i2,
                                                     policy: notificationPolicy,
                                                     conditions: nil,
                                                     now: sixMinutesLater).shouldAlert,
                       "6 minutes does not clear the 20-minute notification gap")
    }

    // MARK: - Dedup is shared

    /// The duplicate-alert bug: a popup fires, the screen locks — which is
    /// instant, not the five-minute idle threshold — and the notification
    /// channel, having no memory of it, alerts again for the same aircraft.
    func testAnAircraftShownAsAPopupDoesNotThenAlertAsANotification() throws {
        let dedupe = AlertGovernor.Dedupe()
        let popupGovernor = AlertGovernor(dedupe: dedupe)
        let notificationGovernor = AlertGovernor(dedupe: dedupe)
        let scorer = InterestScorer()
        let s = interestingSighting(id: "cc0001")
        let interest = try XCTUnwrap(scorer.score(s))
        let now = Date()

        XCTAssertTrue(popupGovernor.evaluate(s, interest: interest, policy: popupPolicy,
                                             conditions: nil, now: now).shouldAlert)
        popupGovernor.record(s, interest: interest, now: now)

        let second = notificationGovernor.evaluate(s, interest: interest,
                                                   policy: notificationPolicy,
                                                   conditions: nil, now: now + 3)
        XCTAssertFalse(second.shouldAlert, "the same aircraft must not alert twice")
        XCTAssertEqual(second.suppressedBecause, "already alerted today")
    }

    /// Without sharing, the same sequence produces the duplicate — proving the
    /// test above would actually catch a regression rather than passing for
    /// some unrelated reason.
    func testWithoutASharedDedupeTheDuplicateWouldGetThrough() throws {
        let popupGovernor = AlertGovernor()
        let notificationGovernor = AlertGovernor()
        let scorer = InterestScorer()
        let s = interestingSighting(id: "cc0002")
        let interest = try XCTUnwrap(scorer.score(s))
        let now = Date()

        popupGovernor.record(s, interest: interest, now: now)
        XCTAssertTrue(notificationGovernor.evaluate(s, interest: interest,
                                                    policy: notificationPolicy,
                                                    conditions: nil, now: now + 3).shouldAlert)
    }

    /// Each governor rolls its own budget over when it first notices a new day.
    /// If the shared set rolled over on those stamps too, the second governor to
    /// wake after midnight would wipe what the first had already recorded that
    /// day — reopening the duplicate. The set carries its own stamp instead.
    func testSharedDedupeRollsOverExactlyOncePerDay() throws {
        let dedupe = AlertGovernor.Dedupe()
        let popupGovernor = AlertGovernor(dedupe: dedupe)
        let notificationGovernor = AlertGovernor(dedupe: dedupe)
        let scorer = InterestScorer()
        let s = interestingSighting(id: "dd0001")
        let interest = try XCTUnwrap(scorer.score(s))

        let today = Date()
        let tomorrow = today.addingTimeInterval(26 * 60 * 60)

        // Yesterday's alert must not suppress tomorrow's.
        popupGovernor.record(s, interest: interest, now: today)
        XCTAssertTrue(popupGovernor.evaluate(s, interest: interest, policy: popupPolicy,
                                             conditions: nil, now: tomorrow).shouldAlert,
                      "a new day clears the dedup set")

        // Popup governor rolls over first and records. The notification governor
        // then wakes for the first time that day — it must not wipe that record.
        popupGovernor.record(s, interest: interest, now: tomorrow)
        XCTAssertFalse(notificationGovernor.evaluate(s, interest: interest,
                                                     policy: notificationPolicy,
                                                     conditions: nil, now: tomorrow).shouldAlert,
                       "the second governor's rollover must not clear today's records")
    }

    // MARK: - Weather

    /// The two policies deliberately disagree after dark. Notifications keep the
    /// daylight rule; popups drop it, because it was silently removing most of
    /// `bigAndLow` and `rotorcraft` at exactly the hours the app gets used. The
    /// card still says "too dark to see", so nothing pretends to be visible.
    func testOrdinaryTrafficPopsAtNightButDoesNotNotify() throws {
        let night = SkyConditions(cloudCoverPercent: 0, visibilityMetres: 20000,
                                  isDaylight: false, fetchedAt: Date())
        let s = interestingSighting(id: "ee0001")
        let bigAndLow = Interest(category: .bigAndLow, score: 90, reason: "large aircraft low")

        XCTAssertTrue(AlertGovernor().evaluate(s, interest: bigAndLow, policy: popupPolicy,
                                               conditions: night).shouldAlert,
                      "popups should fire at night")
        let suppressed = AlertGovernor().evaluate(s, interest: bigAndLow,
                                                  policy: notificationPolicy,
                                                  conditions: night)
        XCTAssertFalse(suppressed.shouldAlert, "notifications keep the daylight rule")
        XCTAssertEqual(suppressed.suppressedBecause, "dark")
    }

    /// Rare types were always exempt from the weather gate, in both policies —
    /// a 747 overhead is worth knowing about whether or not you can see it.
    func testRareTypesWereNeverGatedByDarkness() throws {
        let night = SkyConditions(cloudCoverPercent: 0, visibilityMetres: 20000,
                                  isDaylight: false, fetchedAt: Date())
        let s = interestingSighting(id: "ee0002")
        let rare = Interest(category: .rare, score: 90, reason: "rare type B748")

        XCTAssertTrue(AlertGovernor().evaluate(s, interest: rare, policy: popupPolicy,
                                               conditions: night).shouldAlert)
        XCTAssertTrue(AlertGovernor().evaluate(s, interest: rare, policy: notificationPolicy,
                                               conditions: night).shouldAlert)
    }
}
