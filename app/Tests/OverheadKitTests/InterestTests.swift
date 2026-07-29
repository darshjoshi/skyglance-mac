import XCTest
@testable import OverheadKit

private let observer = Coordinate(latitude: 51.47, longitude: -0.4543)
private let kmPerDegreeLatitude = 111.195

private func make(northKm: Double = 0, eastKm: Double = 0, altitudeFeet: Double,
                  category: String? = nil, type: String? = nil,
                  squawk: String? = nil, dbFlags: Int? = nil,
                  hex: String = "a1b2c3") -> Sighting {
    let lat = observer.latitude + northKm / kmPerDegreeLatitude
    let lon = observer.longitude
        + eastKm / (kmPerDegreeLatitude * cos(observer.latitude * .pi / 180))
    var fields: [String] = [
        "\"hex\":\"\(hex)\"", "\"lat\":\(lat)", "\"lon\":\(lon)", "\"alt_baro\":\(altitudeFeet)",
    ]
    if let category { fields.append("\"category\":\"\(category)\"") }
    if let type { fields.append("\"t\":\"\(type)\"") }
    if let squawk { fields.append("\"squawk\":\"\(squawk)\"") }
    if let dbFlags { fields.append("\"dbFlags\":\(dbFlags)") }
    let json = "{\(fields.joined(separator: ","))}"
    let aircraft = try! JSONDecoder().decode(Aircraft.self, from: Data(json.utf8))
    return Sighting(aircraft: aircraft, observer: observer, sources: ["test"])!
}

final class ViewingProfileTests: XCTestCase {
    let eastFacing = ViewingProfile(bearingCenter: 90, bearingHalfWidth: 75, minimumElevation: 0)

    func testSeesEast() {
        XCTAssertTrue(eastFacing.canSee(make(eastKm: 5, altitudeFeet: 3000)))
    }

    func testCannotSeeWest() {
        XCTAssertFalse(eastFacing.canSee(make(eastKm: -5, altitudeFeet: 3000)),
                       "an east-facing view must not report aircraft behind the building")
    }

    func testArcEdgesUseShortestAngularDistance() {
        // Due north (0°) is 90° from centre — outside a 75° half-width.
        XCTAssertFalse(eastFacing.canSee(make(northKm: 5, altitudeFeet: 3000)))
        // Due south (180°) is likewise 90° away.
        XCTAssertFalse(eastFacing.canSee(make(northKm: -5, altitudeFeet: 3000)))
    }

    func testWrapAroundAtNorth() {
        // A north-facing view must treat 350° and 10° as both visible.
        let northFacing = ViewingProfile(bearingCenter: 0, bearingHalfWidth: 45)
        XCTAssertTrue(northFacing.canSee(make(northKm: 10, eastKm: 1, altitudeFeet: 3000)))
        XCTAssertTrue(northFacing.canSee(make(northKm: 10, eastKm: -1, altitudeFeet: 3000)))
    }

    func testAllSkySeesEverything() {
        for east in [-5.0, 5.0] {
            for north in [-5.0, 5.0] {
                XCTAssertTrue(ViewingProfile.allSky
                    .canSee(make(northKm: north, eastKm: east, altitudeFeet: 3000)))
            }
        }
    }

    func testMinimumElevationBlocksLowTraffic() {
        let blocked = ViewingProfile(bearingCenter: 90, bearingHalfWidth: 90, minimumElevation: 20)
        XCTAssertFalse(blocked.canSee(make(eastKm: 20, altitudeFeet: 2000)))   // ~1.7°
        XCTAssertTrue(blocked.canSee(make(eastKm: 2, altitudeFeet: 10000)))    // ~56°
    }
}

final class InterestScorerTests: XCTestCase {
    let scorer = InterestScorer()

    func testLargeAircraftLowAndCloseScoresHighly() {
        // The Newark-approach case: a 737 at 1,200 ft and 3 km. Only 7° up, so a
        // pure elevation rule would discard it entirely.
        let s = make(eastKm: 3, altitudeFeet: 1200, category: "A3", type: "B738")
        let interest = try! XCTUnwrap(scorer.score(s))
        XCTAssertEqual(interest.category, .bigAndLow)
        XCTAssertGreaterThanOrEqual(interest.score, 70, "should clear the default threshold")
        XCTAssertLessThan(s.elevationDegrees, 20, "and it is nowhere near overhead")
    }

    func testLargeAircraftAtCruiseDoesNotScore() {
        let s = make(eastKm: 3, altitudeFeet: 35000, category: "A3", type: "B738")
        XCTAssertNil(scorer.score(s), "cruise traffic is a dot, not an event")
    }

    func testDistantLargeAircraftDoesNotScore() {
        let s = make(eastKm: 30, altitudeFeet: 1200, category: "A3", type: "B738")
        XCTAssertNil(scorer.score(s))
    }

    func testHelicopterOnlyCountsWhenCloseAndLow() {
        let far = make(eastKm: 9, altitudeFeet: 900, category: "A7", type: "B06")
        XCTAssertNil(scorer.score(far), "the corridor is constant; distant ones must not alert")

        let close = make(eastKm: 1.5, altitudeFeet: 400, category: "A7", type: "B06")
        let interest = try! XCTUnwrap(scorer.score(close))
        XCTAssertEqual(interest.category, .rotorcraft)
    }

    func testRareTypeOutranksBigAndLow() {
        let s = make(eastKm: 3, altitudeFeet: 1200, category: "A3", type: "B748")
        let interest = try! XCTUnwrap(scorer.score(s))
        XCTAssertEqual(interest.category, .rare, "a 747 is the story, not its altitude")
    }

    func testEmergencyBeatsEverything() {
        let s = make(eastKm: 3, altitudeFeet: 1200, category: "A3", type: "B738", squawk: "7700")
        let interest = try! XCTUnwrap(scorer.score(s))
        XCTAssertEqual(interest.category, .emergency)
        XCTAssertEqual(interest.score, 100)
    }

    func testDisabledCategoryIsIgnored() {
        let limited = InterestScorer(enabledCategories: [.rare])
        let s = make(eastKm: 3, altitudeFeet: 1200, category: "A3", type: "B738")
        XCTAssertNil(limited.score(s))
    }
}

final class AlertGovernorTests: XCTestCase {
    let policy = AlertPolicy()
    let clearSky = SkyConditions(cloudCoverPercent: 10, visibilityMetres: 40000,
                                 isDaylight: true, fetchedAt: Date())

    private func interest(_ score: Double, _ category: InterestCategory = .bigAndLow) -> Interest {
        Interest(category: category, score: score, reason: "test")
    }

    func testBelowThresholdIsSuppressed() {
        let governor = AlertGovernor()
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 1200), interest: interest(50),
                                  policy: policy, conditions: clearSky)
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "below score threshold")
    }

    func testSameAircraftNeverAlertsTwice() {
        let governor = AlertGovernor()
        let s = make(eastKm: 3, altitudeFeet: 1200)
        XCTAssertTrue(governor.evaluate(s, interest: interest(90), policy: policy,
                                        conditions: clearSky).shouldAlert)
        governor.record(s, interest: interest(90))
        let second = governor.evaluate(s, interest: interest(90), policy: policy,
                                       conditions: clearSky)
        XCTAssertFalse(second.shouldAlert)
        XCTAssertEqual(second.suppressedBecause, "already alerted today")
    }

    func testQuietGapIsEnforced() {
        // Generous budget so only the cadence rule can fire.
        let gapOnly = AlertPolicy(minimumScore: 70, maximumPerDay: 100, minimumGap: 20 * 60)
        let governor = AlertGovernor()
        let first = make(eastKm: 3, altitudeFeet: 1200, hex: "aaa111")
        governor.record(first, interest: interest(90))
        // A different aircraft, one minute later.
        let second = make(eastKm: 4, altitudeFeet: 1300, category: "A3", hex: "bbb222")
        let d = governor.evaluate(second, interest: interest(90), policy: gapOnly,
                                  conditions: clearSky, now: Date().addingTimeInterval(60))
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "within quiet gap")
    }

    func testDailyBudgetIsSpent() {
        // Gap set to zero and per-category caps lifted so only the global budget
        // can fire — otherwise the test asserts on whichever rule comes first.
        let budgetOnly = AlertPolicy(minimumScore: 70, maximumPerDay: 3, minimumGap: 0,
                                     perCategoryDailyCap: [:])
        let governor = AlertGovernor()
        let now = Date()
        for i in 0..<budgetOnly.maximumPerDay {
            governor.record(make(eastKm: Double(i) + 1, altitudeFeet: 1200, hex: "bud\(i)"),
                            interest: interest(90), now: now)
        }
        let d = governor.evaluate(make(eastKm: 99, altitudeFeet: 1200, hex: "zzz999"),
                                  interest: interest(95), policy: budgetOnly,
                                  conditions: clearSky, now: now)
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "daily budget spent")
    }

    func testOvercastSuppresses() {
        let governor = AlertGovernor()
        let overcast = SkyConditions(cloudCoverPercent: 95, visibilityMetres: 5000,
                                     isDaylight: true, fetchedAt: Date())
        // Above the deck — a low aircraft would legitimately still be visible.
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 9000), interest: interest(90),
                                  policy: policy, conditions: overcast)
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "overcast")
    }

    func testDarknessSuppresses() {
        let governor = AlertGovernor()
        let night = SkyConditions(cloudCoverPercent: 0, visibilityMetres: 40000,
                                  isDaylight: false, fetchedAt: Date())
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 1200), interest: interest(90),
                                  policy: policy, conditions: night)
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "dark")
    }

    func testEmergencyBypassesEveryGate() {
        let governor = AlertGovernor()
        let now = Date()
        for i in 0..<policy.maximumPerDay {   // budget fully spent
            governor.record(make(eastKm: Double(i) + 1, altitudeFeet: 1200, hex: "e\(i)"), interest: interest(90), now: now)
        }
        let night = SkyConditions(cloudCoverPercent: 100, visibilityMetres: 1000,
                                  isDaylight: false, fetchedAt: now)
        let d = governor.evaluate(make(eastKm: 99, altitudeFeet: 1200, hex: "emg777"),
                                  interest: interest(100, .emergency),
                                  policy: policy, conditions: night, now: now)
        XCTAssertTrue(d.shouldAlert, "an emergency must never be rate-limited away")
    }
}

final class CategoryBudgetTests: XCTestCase {
    let clearSky = SkyConditions(cloudCoverPercent: 10, visibilityMetres: 40000,
                                 isDaylight: true, fetchedAt: Date())
    private func interest(_ score: Double, _ c: InterestCategory) -> Interest {
        Interest(category: c, score: score, reason: "test")
    }

    /// The point of per-category lanes: a busy morning of routine approach traffic
    /// must not be able to consume the budget a genuinely rare aircraft needs.
    func testCommonCategoryCannotStarveRareOne() {
        let policy = AlertPolicy(minimumScore: 70, maximumPerDay: 100, minimumGap: 0)
        let governor = AlertGovernor()
        let now = Date()

        // Spend the entire bigAndLow lane.
        let cap = policy.perCategoryDailyCap[.bigAndLow]!
        for i in 0..<cap {
            governor.record(make(eastKm: 3, altitudeFeet: 1200, category: "A3", hex: "big\(i)"),
                            interest: interest(90, .bigAndLow), now: now)
        }
        let anotherAirliner = governor.evaluate(
            make(eastKm: 3, altitudeFeet: 1200, category: "A3", hex: "bigX"),
            interest: interest(90, .bigAndLow), policy: policy, conditions: clearSky, now: now)
        XCTAssertFalse(anotherAirliner.shouldAlert)
        XCTAssertEqual(anotherAirliner.suppressedBecause, "bigAndLow budget spent")

        // The rare lane is untouched.
        let rare = governor.evaluate(
            make(eastKm: 3, altitudeFeet: 1200, category: "A3", type: "B748", hex: "rare1"),
            interest: interest(95, .rare), policy: policy, conditions: clearSky, now: now)
        XCTAssertTrue(rare.shouldAlert, "a rare aircraft must still get through")
    }

    func testEmergencyLaneIsUnbounded() {
        let policy = AlertPolicy(minimumScore: 70, maximumPerDay: 1, minimumGap: 0)
        let governor = AlertGovernor()
        let now = Date()
        for i in 0..<10 {
            governor.record(make(eastKm: 3, altitudeFeet: 1200, hex: "e\(i)"),
                            interest: interest(100, .emergency), now: now)
        }
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 1200, hex: "eNew"),
                                  interest: interest(100, .emergency),
                                  policy: policy, conditions: clearSky, now: now)
        XCTAssertTrue(d.shouldAlert)
    }
}

final class VisibilityGateTests: XCTestCase {
    let policy = AlertPolicy()
    private func interest(_ c: InterestCategory) -> Interest {
        Interest(category: c, score: 95, reason: "test")
    }
    /// Clear night: isolates the darkness gate from the overcast gate.
    let clearNight = SkyConditions(cloudCoverPercent: 10, visibilityMetres: 40000,
                                   isDaylight: false, fetchedAt: Date())

    /// Regression: a 747-400 flew over at night and was suppressed as "dark".
    /// Rare aircraft are exactly what you would get out of bed for.
    func testRareAircraftSurvivesDarkness() {
        let governor = AlertGovernor()
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 8000, category: "A5",
                                       type: "B744", hex: "jumbo1"),
                                  interest: interest(.rare), policy: policy,
                                  conditions: clearNight)
        XCTAssertTrue(d.shouldAlert, "a rare aircraft must not be lost to nightfall")
    }

    /// The 747 that was lost: overcast *and* dark. It must still get through —
    /// the alert wording is what changes, not whether you are told.
    func testRareAircraftSurvivesOvercastAndDarkness() {
        let overcastNight = SkyConditions(cloudCoverPercent: 100, visibilityMetres: 16000,
                                          isDaylight: false, fetchedAt: Date())
        let governor = AlertGovernor()
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 8000, category: "A5",
                                       type: "B744", hex: "jumbo2"),
                                  interest: interest(.rare), policy: policy,
                                  conditions: overcastNight)
        XCTAssertTrue(d.shouldAlert, "a rare aircraft must never be lost to weather")
        XCTAssertFalse(overcastNight.permitsViewing(altitudeFeet: 8000, policy: policy),
                       "...but the app must know it is not visible")
        XCTAssertEqual(overcastNight.obstruction(altitudeFeet: 8000, policy: policy),
                       "too dark to see")
    }

    func testObstructionWordingPrefersCloudInDaylight() {
        let overcastDay = SkyConditions(cloudCoverPercent: 95, visibilityMetres: 8000,
                                        isDaylight: true, fetchedAt: Date())
        XCTAssertEqual(overcastDay.obstruction(altitudeFeet: 9000, policy: policy),
                       "too cloudy to see")
        XCTAssertNil(overcastDay.obstruction(altitudeFeet: 1200, policy: policy),
                     "under the deck is still visible")
    }

    func testRoutineTrafficIsStillSuppressedAtNight() {
        let governor = AlertGovernor()
        let d = governor.evaluate(make(eastKm: 3, altitudeFeet: 9000, category: "A3",
                                       type: "B738", hex: "routine1"),
                                  interest: interest(.bigAndLow), policy: policy,
                                  conditions: clearNight)
        XCTAssertFalse(d.shouldAlert)
        XCTAssertEqual(d.suppressedBecause, "dark")
    }

    /// Under an overcast deck you can still see what is below the cloud base.
    func testLowAircraftSurvivesOvercast() {
        let overcastDay = SkyConditions(cloudCoverPercent: 95, visibilityMetres: 12000,
                                        isDaylight: true, fetchedAt: Date())
        let governor = AlertGovernor()
        let low = governor.evaluate(make(eastKm: 2, altitudeFeet: 1200, category: "A3",
                                         hex: "low1"),
                                    interest: interest(.bigAndLow), policy: policy,
                                    conditions: overcastDay)
        XCTAssertTrue(low.shouldAlert, "an aircraft under the deck is still visible")

        let governor2 = AlertGovernor()
        let high = governor2.evaluate(make(eastKm: 2, altitudeFeet: 12000, category: "A3",
                                           hex: "high1"),
                                      interest: interest(.bigAndLow), policy: policy,
                                      conditions: overcastDay)
        XCTAssertFalse(high.shouldAlert)
        XCTAssertEqual(high.suppressedBecause, "overcast")
    }
}

/// The alert copy is what the user actually reads, and it has four branches.
final class AlertPresentationTests: XCTestCase {
    private func interest(_ c: InterestCategory = .rare, _ reason: String = "rare type B744") -> Interest {
        Interest(category: c, score: 95, reason: reason)
    }
    private let ewr = AirportRef(icao: "KEWR", iata: "EWR", name: "Newark Liberty International Airport",
                                 municipality: "Newark")
    private let edi = AirportRef(icao: "EGPH", iata: "EDI", name: "Edinburgh Airport",
                                 municipality: "Edinburgh")

    func testVisibleWithRouteNamesTheAirlineAndJourney() {
        let route = RouteInfo(airline: "United Airlines", origin: ewr, destination: edi)
        let p = alertPresentation(for: make(eastKm: 3, altitudeFeet: 4200, type: "B752"),
                                  interest: interest(), route: route, obstruction: nil)
        XCTAssertTrue(p.title.hasPrefix("Look "), p.title)
        XCTAssertTrue(p.title.contains("United Airlines"))
        XCTAssertTrue(p.body.contains("Newark → Edinburgh"), p.body)
    }

    func testVisibleWithoutRouteFallsBackToTheReason() {
        let p = alertPresentation(for: make(eastKm: 3, altitudeFeet: 4200, type: "B744"),
                                  interest: interest(), route: nil, obstruction: nil)
        XCTAssertTrue(p.title.contains("rare type B744"), p.title)
        XCTAssertFalse(p.body.contains("→"), "a missing route must not render an arrow")
    }

    /// The 747 case: you are told, but never told to look at nothing.
    func testObstructedNeverSaysLook() {
        let route = RouteInfo(airline: "Cargolux", origin: ewr, destination: edi)
        let p = alertPresentation(for: make(eastKm: 3, altitudeFeet: 8000, type: "B744"),
                                  interest: interest(), route: route,
                                  obstruction: "too dark to see")
        XCTAssertFalse(p.title.contains("Look"), "must not point at an invisible sky: \(p.title)")
        XCTAssertTrue(p.title.contains("passed overhead"), p.title)
        XCTAssertTrue(p.body.contains("too dark to see"), p.body)
        XCTAssertTrue(p.body.contains("Cargolux"), p.body)
    }

    func testObstructedWithoutRouteStillExplainsWhy() {
        let p = alertPresentation(for: make(eastKm: 3, altitudeFeet: 8000, type: "B744"),
                                  interest: interest(), route: nil,
                                  obstruction: "too cloudy to see")
        XCTAssertFalse(p.title.contains("Look"))
        XCTAssertTrue(p.body.contains("too cloudy to see"), p.body)
        XCTAssertFalse(p.body.contains("→"))
    }

    func testHalfRouteIsTreatedAsNoRoute() {
        let half = RouteInfo(airline: "United Airlines", origin: ewr, destination: nil)
        let p = alertPresentation(for: make(eastKm: 3, altitudeFeet: 4200, type: "B752"),
                                  interest: interest(), route: half, obstruction: nil)
        XCTAssertFalse(p.body.contains("→"), "half a route must never render as an arrow")
        XCTAssertTrue(p.title.contains("rare type"), p.title)
    }
}

final class MenuBarSummaryTests: XCTestCase {
    private func overheadSighting() -> Sighting {
        make(eastKm: 1, altitudeFeet: 20000, category: "A3", type: "B738")
    }

    /// The count must always be visible — the whole point of the change.
    func testShowsCountWhenNothingIsOverhead() {
        XCTAssertEqual(menuBarSummary(totalCount: 28, headline: nil,
                                      isStale: false, hasError: false), "28")
    }

    func testShowsCountAndHeadlineTogether() {
        let s = overheadSighting()
        XCTAssertTrue(s.isOverhead)
        let text = menuBarSummary(totalCount: 28, headline: s, isStale: false, hasError: false)
        XCTAssertTrue(text.hasPrefix("28 · "), text)
        XCTAssertTrue(text.contains("B738"), text)
    }

    /// A quiet sky, stale data and a broken backend must all look different.
    func testFailureStatesRemainDistinguishable() {
        let quiet = menuBarSummary(totalCount: 0, headline: nil, isStale: false, hasError: false)
        let stale = menuBarSummary(totalCount: 28, headline: nil, isStale: true, hasError: false)
        let broken = menuBarSummary(totalCount: 0, headline: nil, isStale: false, hasError: true)
        let unset = menuBarSummary(totalCount: 0, headline: nil, isStale: false,
                                   hasError: false, isConfigured: false)
        XCTAssertEqual(quiet, "no contact")
        XCTAssertEqual(stale, "28 ⏳")
        XCTAssertEqual(broken, "⚠︎")
        XCTAssertEqual(unset, "set up")
        XCTAssertEqual(Set([quiet, stale, broken, unset]).count, 4,
                       "these must never collide")
    }

    /// "Never configured" outranks every other state. A brand-new install has an
    /// empty sky and no sources, which otherwise renders identically to a working
    /// app on a quiet night — and only one of the two is the user's to fix.
    func testUnconfiguredOverridesEverythingElse() {
        for (stale, error) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertEqual(
                menuBarSummary(totalCount: 0, headline: nil, isStale: stale,
                               hasError: error, isConfigured: false),
                "set up")
        }
    }

    func testStaysShortEnoughForAMenuBar() {
        let text = menuBarSummary(totalCount: 285, headline: overheadSighting(),
                                  isStale: false, hasError: false)
        XCTAssertLessThanOrEqual(text.count, 18, "menu bar space is scarce: \(text)")
    }
}
