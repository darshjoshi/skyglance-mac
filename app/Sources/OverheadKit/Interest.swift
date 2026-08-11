import Foundation

/// What you can actually see from where you sit. Aircraft outside the arc are
/// discarded before scoring — at a location with a one-sided view this throws
/// away roughly half the traffic and buys back most of the alert budget.
public struct ViewingProfile: Codable, Sendable {
    /// Centre of the visible arc, in compass degrees. 90 = due east.
    public var bearingCenter: Double
    /// Half-width of the arc. 75 gives a 150° window.
    public var bearingHalfWidth: Double
    /// Below this elevation the view is blocked by buildings or terrain.
    public var minimumElevation: Double

    public init(bearingCenter: Double = 90, bearingHalfWidth: Double = 75,
                minimumElevation: Double = 0) {
        self.bearingCenter = bearingCenter
        self.bearingHalfWidth = bearingHalfWidth
        self.minimumElevation = minimumElevation
    }

    /// Looks in every direction — the right default when the view is unobstructed.
    public static let allSky = ViewingProfile(bearingCenter: 0, bearingHalfWidth: 180,
                                              minimumElevation: 0)

    public func canSee(_ s: Sighting) -> Bool {
        guard s.elevationDegrees >= minimumElevation else { return false }
        guard bearingHalfWidth < 180 else { return true }
        // Shortest angular distance between the two bearings, handling wraparound
        // at north: ((b - c + 540) mod 360) - 180 lands in [-180, 180).
        let delta = abs(((s.bearingDegrees - bearingCenter + 540)
            .truncatingRemainder(dividingBy: 360)) - 180)
        return delta <= bearingHalfWidth
    }
}

public enum InterestCategory: String, Codable, Sendable, CaseIterable {
    case emergency, rare, bigAndLow, rotorcraft, military

    public var priority: Int {
        switch self {
        case .emergency: return 4
        case .rare: return 3
        case .military: return 2
        case .bigAndLow: return 1
        case .rotorcraft: return 0
        }
    }
}

public struct Interest: Sendable {
    public let category: InterestCategory
    public let score: Double        // 0–100
    public let reason: String

    // Swift keeps the memberwise initialiser internal on a public struct, so
    // every field being public was not enough to build one from outside.
    public init(category: InterestCategory, score: Double, reason: String) {
        self.category = category
        self.score = score
        self.reason = reason
    }
}

/// Scores are deliberately harsh. At a location with 85 large aircraft below
/// 10,000 ft and a dozen helicopters up at any moment, a generous scorer produces
/// a notification every ninety seconds, which is indistinguishable from spam.
public struct InterestScorer: Sendable {
    public var enabledCategories: Set<InterestCategory>
    public var rareTypes: Set<String>

    public init(enabledCategories: Set<InterestCategory> = Set(InterestCategory.allCases),
                rareTypes: Set<String> = rareTypeCodes) {
        self.enabledCategories = enabledCategories
        self.rareTypes = rareTypes
    }

    public func score(_ s: Sighting) -> Interest? {
        var candidates: [Interest] = []

        if enabledCategories.contains(.emergency), s.hasEmergency {
            candidates.append(Interest(category: .emergency, score: 100,
                                       reason: "squawking emergency"))
        }

        if enabledCategories.contains(.rare),
           let type = s.typeCode, rareTypes.contains(type.uppercased()) {
            // Rare enough that distance barely matters; you'd walk outside for it.
            let proximity = max(0, 1 - s.slantRangeKm / 40)
            candidates.append(Interest(category: .rare, score: 75 + 20 * proximity,
                                       reason: "rare type \(type)"))
        }

        if enabledCategories.contains(.military), s.isMilitary {
            let proximity = max(0, 1 - s.slantRangeKm / 40)
            candidates.append(Interest(category: .military, score: 70 + 20 * proximity,
                                       reason: "military"))
        }

        // Big and low: an airliner on approach is enormous and unmistakable even
        // at a shallow angle, which is exactly what a pure elevation rule misses.
        if enabledCategories.contains(.bigAndLow), s.isLarge,
           s.altitudeFeet <= 4000, s.slantRangeKm <= 8 {
            let lowness = 1 - min(1, s.altitudeFeet / 4000)
            let closeness = 1 - min(1, s.slantRangeKm / 8)
            candidates.append(Interest(category: .bigAndLow,
                                       score: 45 + 50 * (0.5 * lowness + 0.5 * closeness),
                                       reason: "large aircraft low overhead"))
        }

        // Rotorcraft are constant near any city with a heliport, so only the genuinely close and low ones
        // clear the bar — otherwise this category alone would exhaust the budget.
        if enabledCategories.contains(.rotorcraft), s.isRotorcraft,
           s.altitudeFeet <= 1500, s.slantRangeKm <= 5 {
            let lowness = 1 - min(1, s.altitudeFeet / 1500)
            let closeness = 1 - min(1, s.slantRangeKm / 5)
            candidates.append(Interest(category: .rotorcraft,
                                       score: 40 + 45 * (0.4 * lowness + 0.6 * closeness),
                                       reason: "helicopter close and low"))
        }

        return candidates.max { a, b in
            a.score == b.score ? a.category.priority < b.category.priority : a.score < b.score
        }
    }
}

/// Enforces "a few times a day". Without this the scorer alone still fires far
/// too often, because interesting things cluster.
public struct AlertPolicy: Codable, Sendable {
    public var minimumScore: Double
    public var maximumPerDay: Int
    public var minimumGap: TimeInterval
    /// Don't alert about weather you can't see through, or a sky you can't see.
    public var requireDaylight: Bool
    public var maximumCloudCover: Int

    /// Per-category ceilings. A single global budget is spent first-come, so a
    /// morning of routine Newark arrivals would consume the whole day and a 747
    /// at noon would be silently dropped. Reserving a lane per category keeps the
    /// rare things alertable no matter how busy the common ones are.
    public var perCategoryDailyCap: [InterestCategory: Int]

    /// Categories worth telling you about whatever the sky is doing. A 747-400
    /// over the house is a rare event even when cloud makes it invisible —
    /// losing it to weather loses precisely what the app exists for. The alert
    /// wording changes instead; see `SkyConditions.permitsViewing`.
    public var categoriesIgnoringWeather: Set<InterestCategory>

    /// Below this, an aircraft is likely under the cloud deck and still visible
    /// even when the sky is reported overcast.
    public var underCloudCeilingFeet: Double

    public init(minimumScore: Double = 70, maximumPerDay: Int = 8,
                minimumGap: TimeInterval = 20 * 60, requireDaylight: Bool = true,
                maximumCloudCover: Int = 80,
                categoriesIgnoringWeather: Set<InterestCategory> = [.emergency, .rare, .military],
                underCloudCeilingFeet: Double = 2500,
                perCategoryDailyCap: [InterestCategory: Int] = [
                    .emergency: Int.max,   // never rate-limited
                    .rare: 4,
                    .military: 3,
                    .bigAndLow: 3,
                    .rotorcraft: 2,
                ]) {
        self.minimumScore = minimumScore
        self.maximumPerDay = maximumPerDay
        self.minimumGap = minimumGap
        self.requireDaylight = requireDaylight
        self.maximumCloudCover = maximumCloudCover
        self.categoriesIgnoringWeather = categoriesIgnoringWeather
        self.underCloudCeilingFeet = underCloudCeilingFeet
        self.perCategoryDailyCap = perCategoryDailyCap
    }
}

public extension AlertPolicy {
    /// What a popup costs, as opposed to the defaults, which are the banner's.
    ///
    /// A card that fades by itself and leaves nothing in Notification Center is
    /// cheaper to ignore than a banner that stacks up, so it earns a looser
    /// budget — roughly twice the volume at a quarter of the gap. Still bounded:
    /// an uncapped popup channel is one you end up switching off.
    ///
    /// This is what a first-time user gets, and it is deliberately the
    /// conservative of the two. The scorer's `bigAndLow` fires for any large
    /// aircraft within 8 km and below 4,000 ft, which under an approach path is
    /// close to continuous — someone living near Heathrow should not be
    /// carpet-bombed by an app they installed ten minutes ago.
    ///
    /// Defined here, beside the defaults it is compared against, so the app and
    /// its tests read the same numbers. A hand-copied duplicate in the test file
    /// had already drifted from the real thing once.
    static let popupDefaults = AlertPolicy(
        maximumPerDay: 20, minimumGap: 5 * 60,
        perCategoryDailyCap: [
            .emergency: Int.max,
            .rare: 10,
            .military: 8,
            .bigAndLow: 8,
            .rotorcraft: 5,
        ])

    /// Opt-in, for a quiet sky or someone who simply wants more of them.
    ///
    /// `minimumScore` at 55 rather than 70 does the most work here. Rare and
    /// military score 70+ by construction and are unaffected, but `bigAndLow`
    /// spans 45–95 and `rotorcraft` 40–85, so 70 admitted only the upper half of
    /// each — an airliner had to be both very low *and* very close. At 55 the
    /// merely-close ones qualify. The scorer's own hard gates are untouched, so
    /// this widens what counts as interesting among aircraft already worth
    /// scoring; it cannot invent popups from an empty sky.
    ///
    /// `requireDaylight` is off. Only rare, military and emergency carry the
    /// weather exemption, so leaving it on silently removed most of `bigAndLow`
    /// and `rotorcraft` after dark. The card still reads "too dark to see", so
    /// nothing pretends to be visible.
    static let popupFrequent = AlertPolicy(
        minimumScore: 55, maximumPerDay: 40, minimumGap: 2 * 60,
        requireDaylight: false,
        perCategoryDailyCap: [
            .emergency: Int.max,
            .rare: 20,
            .military: 16,
            .bigAndLow: 16,
            .rotorcraft: 10,
        ])
}

public struct AlertDecision: Sendable {
    public let shouldAlert: Bool
    public let suppressedBecause: String?
}

/// Tracks what has already been sent so the same aircraft never alerts twice and
/// the daily budget is actually honoured.
public final class AlertGovernor: @unchecked Sendable {

    /// "Which aircraft already interrupted you today", shared between governors.
    ///
    /// An app with two delivery channels needs two budgets — a popup that fades
    /// by itself can afford to fire more often than a banner that stacks up —
    /// but it must not have two answers to "have I already told you about this
    /// aircraft". Without sharing, seeing a popup and then locking the screen
    /// produced a second, duplicate alert for the same aircraft through the
    /// other channel.
    ///
    /// The day stamp lives in here rather than in the governor. Each governor
    /// rolls its own budget over when it first notices a new day, and if this
    /// set rolled over on *their* stamps, the second governor to wake after
    /// midnight would clear entries the first had already written that day —
    /// wiping exactly the record that prevents the duplicate.
    public final class Dedupe: @unchecked Sendable {
        fileprivate var ids: Set<String> = []
        fileprivate var dayStamp: Int = -1
        public init() {}

        fileprivate func rolloverIfNeeded(_ day: Int) {
            guard day != dayStamp else { return }
            dayStamp = day
            ids.removeAll()
        }
    }

    private let dedupe: Dedupe
    private var sentTimes: [Date] = []
    private var sentPerCategory: [InterestCategory: Int] = [:]
    private var dayStamp: Int = -1
    private let calendar = Calendar.current

    /// Defaults to a private set, so a lone governor behaves exactly as before.
    public init(dedupe: Dedupe = Dedupe()) {
        self.dedupe = dedupe
    }

    private func rolloverIfNeeded(_ now: Date) {
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        dedupe.rolloverIfNeeded(day)
        if day != dayStamp {
            dayStamp = day
            sentTimes.removeAll()
            sentPerCategory.removeAll()
        }
    }

    public func evaluate(_ s: Sighting, interest: Interest, policy: AlertPolicy,
                         conditions: SkyConditions?, now: Date = Date()) -> AlertDecision {
        rolloverIfNeeded(now)

        if interest.score < policy.minimumScore {
            return AlertDecision(shouldAlert: false, suppressedBecause: "below score threshold")
        }
        // Keyed by category, not just aircraft: something that already alerted as
        // "big and low" and then starts squawking 7700 is new information.
        if dedupe.ids.contains(Self.key(s, interest)) {
            return AlertDecision(shouldAlert: false, suppressedBecause: "already alerted today")
        }
        // Emergencies ignore budget, cadence and weather — that's the point of them.
        if interest.category != .emergency {
            // A category with no entry has no lane of its own; only the global
            // ceiling applies to it.
            let cap = policy.perCategoryDailyCap[interest.category] ?? Int.max
            if (sentPerCategory[interest.category] ?? 0) >= cap {
                return AlertDecision(shouldAlert: false,
                                     suppressedBecause: "\(interest.category.rawValue) budget spent")
            }
            if sentTimes.count >= policy.maximumPerDay {
                return AlertDecision(shouldAlert: false, suppressedBecause: "daily budget spent")
            }
            if let last = sentTimes.last, now.timeIntervalSince(last) < policy.minimumGap {
                return AlertDecision(shouldAlert: false, suppressedBecause: "within quiet gap")
            }
            // Weather only silences the ordinary. Rare and military still get
            // through — reworded to admit you cannot see them.
            if let conditions, !policy.categoriesIgnoringWeather.contains(interest.category),
               !conditions.permitsViewing(altitudeFeet: s.altitudeFeet, policy: policy) {
                return AlertDecision(shouldAlert: false,
                                     suppressedBecause: conditions.isDaylight ? "overcast" : "dark")
            }
        }
        return AlertDecision(shouldAlert: true, suppressedBecause: nil)
    }

    public func record(_ s: Sighting, interest: Interest, now: Date = Date()) {
        rolloverIfNeeded(now)
        dedupe.ids.insert(Self.key(s, interest))
        sentTimes.append(now)
        sentPerCategory[interest.category, default: 0] += 1
    }

    private static func key(_ s: Sighting, _ interest: Interest) -> String {
        "\(s.id):\(interest.category.rawValue)"
    }

    public var sentTodayCount: Int { sentTimes.count }
    public func sentToday(_ category: InterestCategory) -> Int { sentPerCategory[category] ?? 0 }
}

// ── Alert wording ─────────────────────────────────────────────────────────────

public struct AlertPresentation: Equatable, Sendable {
    public let title: String
    public let body: String
}

/// Pure so the copy can be tested. Four branches, and the important one is the
/// obstruction case: when the sky shows nothing, the alert must not say "Look".
public func alertPresentation(for s: Sighting, interest: Interest,
                              route: RouteInfo?, obstruction: String?) -> AlertPresentation {
    let what = s.description ?? s.typeCode ?? s.label
    let journey = (route?.isComplete == true)
        ? "\(route!.origin!.shortName) → \(route!.destination!.shortName)"
        : nil

    var position: [String] = []
    if s.altitudeFeet > 0 { position.append("\(Int(s.altitudeFeet) / 100 * 100) ft") }
    position.append(Distance.format(kilometres: s.slantRangeKm))

    if let obstruction {
        var parts: [String] = []
        if let airline = route?.airline { parts.append(airline) }
        if let journey { parts.append(journey) }
        parts.append(obstruction)
        parts.append(contentsOf: position)
        return AlertPresentation(title: "\(what) passed overhead",
                                 body: parts.joined(separator: " · "))
    }

    position.append("\(Int(s.elevationDegrees))° up")
    if let airline = route?.airline, let journey {
        return AlertPresentation(title: "Look \(s.lookDirection) — \(airline)",
                                 body: ([journey, what] + position).joined(separator: " · "))
    }
    return AlertPresentation(title: "Look \(s.lookDirection) — \(interest.reason)",
                             body: ([what] + position).joined(separator: " · "))
}

/// The menu bar string. Pure, because it is the most-read text in the app and
/// has historically been the place where "quiet sky" and "broken app" looked
/// identical. The count leads: it is the one thing that is always true.
public func menuBarSummary(totalCount: Int, headline: Sighting?,
                           isStale: Bool, hasError: Bool,
                           isConfigured: Bool = true) -> String {
    // Before anything else: an app that has never been told where it is has no
    // opinion about the sky, and must not borrow the vocabulary of one that has.
    if !isConfigured { return "set up" }
    if hasError { return "⚠︎" }
    if totalCount == 0 { return isStale ? "—" : "no contact" }

    let count = "\(totalCount)"
    guard let s = headline else { return isStale ? "\(count) ⏳" : count }

    let what = s.typeCode ?? s.label
    if s.isOverhead { return "\(count) · \(what) \(Int(s.elevationDegrees))°" }
    if let cpa = s.closestApproach { return "\(count) · \(what) \(Int(cpa.secondsAway))s" }
    return "\(count) · \(what)"
}
