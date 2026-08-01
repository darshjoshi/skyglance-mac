import Foundation
import OverheadKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// A sighting paired with whether you could actually look at it. Out-of-arc
/// aircraft are kept — losing them costs situational awareness — but they are
/// never allowed to become the headline and are drawn demoted.
struct Observed: Identifiable {
    let sighting: Sighting
    let isVisible: Bool
    /// When this aircraft first entered range, so the dome can fade it in rather
    /// than pop it. `.distantPast` means "already here" — the safe default.
    var appearedAt: Date = .distantPast
    /// Set once it drops out of range; it lingers briefly to fade out.
    var vanishedAt: Date?
    /// Where it has actually been, oldest first — one sample per poll. Recorded
    /// rather than extrapolated: over three minutes near three major airports
    /// aircraft turn constantly, and a straight synthetic tail would confidently
    /// point the wrong way.
    var trail: [SkyPoint] = []
    var id: String { sighting.id }
}

@MainActor
final class SkyModel: ObservableObject {
    @Published private(set) var overhead: [Observed] = []
    @Published private(set) var inbound: [Observed] = []
    @Published private(set) var nearest: [Observed] = []
    /// Everything in range, for the dome. The list is trimmed for readability;
    /// the dome is not — drawing a glyph costs nothing and a dome showing eight
    /// of twenty-three aircraft contradicts the count in the footer.
    @Published private(set) var domeContents: [Observed] = []
    @Published private(set) var conditions: SkyConditions?
    @Published private(set) var totalCount = 0
    @Published private(set) var sources: [String] = []
    @Published private(set) var isStale = false
    @Published private(set) var error: String?
    @Published private(set) var alertsToday = 0
    @Published private(set) var lastSuppression: String?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var selectedID: String?
    @Published private(set) var detail: AircraftDetail?
    @Published private(set) var isLoadingDetail = false
    /// Nil until asked. Surfaced in the footer, because alerts are the whole
    /// product and a silent denial makes the app look broken for no visible reason.
    @Published private(set) var notificationsAllowed: Bool?

    /// Popups fired today, alongside `alertsToday`. Two channels, two counts —
    /// showing one total would make the footer lie about whichever fired.
    @Published private(set) var popupsToday = 0

    private let client = FeedClient()
    private let weather = WeatherClient()
    private let scorer = InterestScorer()
    private let enrichment = EnrichmentClient()
    private let governor = AlertGovernor()
    private var pollTask: Task<Void, Never>?

    /// A popup is lighter than a notification — it fades by itself and leaves
    /// nothing in Notification Center — so it earns a looser budget than the
    /// 8/day the banner gets. Still capped: this is the difference between an
    /// app you keep and one you mute. Per-category lanes are kept in proportion
    /// so a busy morning of arrivals still cannot crowd out a 747 at noon.
    let popupPolicy = AlertPolicy(maximumPerDay: 20, minimumGap: 5 * 60,
                                  perCategoryDailyCap: [
                                      .emergency: Int.max,
                                      .rare: 10,
                                      .military: 8,
                                      .bigAndLow: 8,
                                      .rotorcraft: 5,
                                  ])
    private let popupGovernor = AlertGovernor()
    let popups = FlightPopupPresenter()

    /// Off means the system notification handles everything, as before.
    var popupsEnabled: Bool {
        get {
            // `object(forKey:)` rather than `bool(forKey:)`: the latter returns
            // false for "never set", which would ship the feature switched off.
            UserDefaults.standard.object(forKey: "popupsEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "popupsEnabled")
            if !newValue { popups.dismiss() }
            objectWillChange.send()
        }
    }

    /// First time each aircraft was seen, kept across polls so the fade-in isn't
    /// restarted every three seconds. Pruned to whatever is still in range.
    private var appearedAt: [String: Date] = [:]
    /// Aircraft that have just left range, retained only long enough to fade.
    private var ghosts: [Observed] = []
    private static let ghostLifetime: TimeInterval = 1.0
    /// Observed sky positions per aircraft, one per poll. Three minutes is enough
    /// for a readable tail on even the slowest-looking traffic; 90 samples of two
    /// doubles across ~40 aircraft is a few tens of kilobytes.
    private var history: [String: [SkyPoint]] = [:]
    private static let historyLength = 60
    /// Set only by `--render --at`; never persisted.
    private var previewCoordinate: Coordinate?
    /// A hard bound on dome glyphs. New York peaks around 60 within 60 nm; this
    /// exists so a feed anomaly cannot make the panel crawl.
    private static let maximumDomeGlyphs = 90

    let policy = AlertPolicy()

    init() {
        // Polling must begin with the model, not when the panel is first opened.
        // With .menuBarExtraStyle(.window) the content view is only instantiated
        // on open, so anything started from it would never run in the background
        // — and background alerting is the entire product.
        start()
    }

    // MARK: - Settings

    /// Nil until the user says where they are. There is deliberately no default
    /// location: any guess would show someone a sky that is not theirs while
    /// looking exactly like a correctly configured app.
    var observer: Coordinate? {
        get {
            if let previewCoordinate { return previewCoordinate }
            let d = UserDefaults.standard
            // `object(forKey:)` rather than `double(forKey:)` — the latter returns
            // 0 for a missing key, and 0,0 is a real place in the Atlantic.
            guard d.object(forKey: "latitude") != nil else { return nil }
            return Coordinate(latitude: d.double(forKey: "latitude"),
                              longitude: d.double(forKey: "longitude"))
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue.latitude, forKey: "latitude")
            UserDefaults.standard.set(newValue.longitude, forKey: "longitude")
            // Every recorded sky position was measured from the previous location
            // and is now wrong; keeping them would draw trails that never happened.
            history.removeAll()
            domeContents = []
            objectWillChange.send()
            restart()
        }
    }

    var isConfigured: Bool { observer != nil }

    /// Poll somewhere without saving it, for `--render --at`. Kept separate from
    /// the `observer` setter so a screenshot can never overwrite a real setting.
    func previewOnly(at coordinate: Coordinate) {
        previewCoordinate = coordinate
        history.removeAll()
        domeContents = []
        restart()
    }

    var viewingProfile: ViewingProfile {
        get {
            let d = UserDefaults.standard
            // All-round is the right default: most people have sky in every
            // direction, and a one-sided view is the special case. The arc is a
            // hard gate on both the menu bar headline and every notification, so
            // a wrong default silently blinds half the app.
            guard d.object(forKey: "bearingCenter") != nil else { return .allSky }
            return ViewingProfile(bearingCenter: d.double(forKey: "bearingCenter"),
                                  bearingHalfWidth: d.double(forKey: "bearingHalfWidth"),
                                  minimumElevation: d.double(forKey: "minimumElevation"))
        }
        set {
            // All three keys, always. The getter's sentinel is `bearingCenter`
            // alone, so writing it without the others leaves them at
            // `double(forKey:)`'s zero — a 0°-wide arc that hides every aircraft.
            let d = UserDefaults.standard
            d.set(newValue.bearingCenter, forKey: "bearingCenter")
            d.set(newValue.bearingHalfWidth, forKey: "bearingHalfWidth")
            d.set(newValue.minimumElevation, forKey: "minimumElevation")
            objectWillChange.send()
        }
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLaunchAtLogin() {
        do {
            if launchesAtLogin { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            objectWillChange.send()
        } catch {
            self.error = "Login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection

    /// Searched against the full dome contents, not the trimmed list: an aircraft
    /// you are reading about must not disappear mid-sentence because a closer one
    /// pushed it past the list's eighth row.
    var selected: Observed? {
        guard let selectedID else { return nil }
        return domeContents.first { $0.id == selectedID && $0.vanishedAt == nil }
    }

    /// Enrichment is on-demand only: these are volunteer-run services, so a
    /// lookup happens when you deliberately select something, never per poll.
    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        detail = nil
        guard let id, let target = selected else {
            isLoadingDetail = false
            return
        }
        isLoadingDetail = true
        let sighting = target.sighting
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.enrichment.detail(hex: id,
                                                      callsign: sighting.callsign,
                                                      registration: sighting.registration)
            // Discard if the user moved on while this was in flight.
            guard self.selectedID == id else { return }
            self.detail = loaded
            self.isLoadingDetail = false
        }
    }

    // MARK: - Headline

    /// Only ever something you could actually see. This is what the menu bar shows,
    /// so it must never point at an aircraft behind the building.
    var headline: Observed? {
        overhead.first(where: \.isVisible) ?? inbound.first(where: \.isVisible)
    }

    var menuBarText: String {
        menuBarSummary(totalCount: totalCount, headline: headline?.sighting,
                       isStale: isStale, hasError: error != nil,
                       isConfigured: isConfigured)
    }

    // MARK: - Polling

    func start() { restart() }

    /// Asked once setup is finished rather than from `init`, so the very first
    /// thing a new user sees is not a permission prompt from an app whose window
    /// they have not seen yet. The answer is kept: a silent denial would leave
    /// the footer counting alerts that were never delivered.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.notificationsAllowed = granted }
            }
    }

    func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.notificationsAllowed = allowed }
        }
    }

    func restart() {
        pollTask?.cancel()
        // Nothing to poll until we know where the user is. Polling a guessed
        // location would fill the panel with a stranger's sky.
        guard let coordinate = observer else {
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.client.snapshot(around: coordinate, radiusNauticalMiles: 60)
                let sky = await self.weather.conditions(at: coordinate)
                self.apply(SkyState(snapshot: snapshot), conditions: sky)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func refreshNow() { restart() }

    private func apply(_ state: SkyState, conditions: SkyConditions?) {
        let profile = viewingProfile
        let now = Date()
        let mark = { [self] (s: Sighting) -> Observed in
            let first = appearedAt[s.id] ?? now
            appearedAt[s.id] = first
            var past = history[s.id] ?? []
            past.append(SkyPoint(bearingDegrees: s.bearingDegrees,
                                 elevationDegrees: s.elevationDegrees))
            if past.count > Self.historyLength { past.removeFirst(past.count - Self.historyLength) }
            history[s.id] = past
            return Observed(sighting: s, isVisible: profile.canSee(s),
                            appearedAt: first, trail: past)
        }

        // Keep each list in its natural order — elevation, then time, then true
        // distance. Sorting visible-first and *then* capping silently turned
        // "demote" into "hide", and made a list labelled "Nearest" show aircraft
        // 20 km away while dropping one at 3 km for being out of view.
        // Visibility is communicated by styling, not by ordering.
        overhead = state.overheadNow.map(mark)
        inbound = state.inboundSoon.map(mark)
        let everything = state.nearest.prefix(Self.maximumDomeGlyphs).map(mark)
        nearest = Array(everything.prefix(8))

        let live = Set(everything.map(\.id))
        // Anything that was on the dome and isn't any more lingers for a moment so
        // it fades. Without this a departing aircraft simply blinks out, which
        // reads as a glitch rather than as leaving.
        let departing = domeContents.filter { $0.vanishedAt == nil && !live.contains($0.id) }
            .map { Observed(sighting: $0.sighting, isVisible: $0.isVisible,
                            appearedAt: $0.appearedAt, vanishedAt: now) }
        ghosts = (ghosts + departing).filter {
            !live.contains($0.id)
                && now.timeIntervalSince($0.vanishedAt ?? now) < Self.ghostLifetime
        }
        domeContents = everything + ghosts
        appearedAt = appearedAt.filter { live.contains($0.key) }
        history = history.filter { live.contains($0.key) }

        totalCount = state.nearest.count
        sources = state.sources
        isStale = state.isStale
        error = state.error
        self.conditions = conditions
        lastUpdate = state.capturedAt

        considerAlerting()
    }

    private func considerAlerting() {
        // Only visible aircraft can earn an interruption.
        let candidates = nearest.filter(\.isVisible).compactMap { o -> (Sighting, Interest)? in
            guard let interest = scorer.score(o.sighting) else { return nil }
            return (o.sighting, interest)
        }
        guard let (sighting, interest) = candidates.max(by: { $0.1.score < $1.1.score }) else { return }

        // A popup is worth showing only to someone who is actually here — the
        // aircraft is gone in about a minute. Away, or popups switched off, and
        // the notification takes over so the alert waits in Notification Center.
        // Never both: two things for one aircraft reads as a bug.
        let wantsPopup = popupsEnabled && UserPresence.isPresent()

        let decision = wantsPopup
            ? popupGovernor.evaluate(sighting, interest: interest,
                                     policy: popupPolicy, conditions: conditions)
            : governor.evaluate(sighting, interest: interest,
                                policy: policy, conditions: conditions)

        guard decision.shouldAlert else {
            // Surfacing *why* nothing fired is the difference between a tunable
            // app and a silent one.
            lastSuppression = decision.suppressedBecause.map {
                "\(sighting.typeCode ?? sighting.label): \($0)"
            }
            return
        }
        lastSuppression = nil

        // Recorded against the channel that actually fired, so an evening spent
        // away from the desk does not quietly burn the popup budget.
        if wantsPopup {
            popupGovernor.record(sighting, interest: interest)
            popupsToday = popupGovernor.sentTodayCount
            deliverPopup(sighting, interest)
        } else {
            governor.record(sighting, interest: interest)
            alertsToday = governor.sentTodayCount
            notify(sighting, interest)
        }
    }

    /// Builds the card, shows it, and lets the photo catch up.
    ///
    /// Falls back to a notification if there is nowhere to anchor — the ✈ can be
    /// hidden under the notch or by a menu bar manager, and dropping the alert
    /// silently would be worse than showing the plain banner.
    private func deliverPopup(_ s: Sighting, _ interest: Interest) {
        let obstruction = conditions?.obstruction(altitudeFeet: s.altitudeFeet, policy: policy)
        Task { [weak self] in
            guard let self else { return }
            // Deliberately *not* awaited before the card appears. The
            // notification path waits up to two seconds for a route because a
            // banner is a single shot; a popup is on screen for twelve seconds
            // and can fill itself in. Two seconds of nothing is a long time
            // when the whole promise is "look up now".
            //
            // The headline is built with `route: nil` on purpose, so it reads
            // "Look SE — rare type B748" and never rewrites itself under the
            // reader's eyes when the airline arrives — the airline has its own
            // row.
            let presentation = alertPresentation(for: s, interest: interest,
                                                 route: nil, obstruction: obstruction)
            // Only the *title* is reused. `presentation.body` crams operator,
            // route and position into one string because a notification has two
            // lines to work with — but the card gives operator and route their
            // own rows, so reusing it verbatim printed them twice and then
            // truncated the part that was not shown anywhere else.
            var facts: [String] = []
            if let obstruction { facts.append(obstruction) }
            if s.altitudeFeet > 0 { facts.append("\(Int(s.altitudeFeet) / 100 * 100) ft") }
            facts.append(String(format: "%.1f km", s.slantRangeKm))
            facts.append("\(Int(s.elevationDegrees))° up")

            let content = FlightPopupContent(
                id: s.id,
                headline: presentation.title,
                detail: facts.joined(separator: " · "),
                typeLabel: s.typeCode ?? s.label,
                operatorName: nil,
                route: nil,
                trackDegrees: s.trackDegrees,
                categoryTint: SkyDomeView.tint(for: s),
                photoURL: nil)

            guard self.popups.show(content) else {
                // No anchor — hand it back to the notification path, and give the
                // budget back too so a hidden menu bar item cannot silently eat
                // the day's popups.
                self.popupsToday = self.popupGovernor.sentTodayCount
                let route = await Self.withDeadline(seconds: 2) {
                    await self.enrichment.route(callsign: s.callsign)
                }
                self.post(s, interest, route: route, obstruction: obstruction)
                return
            }

            // Everything from here fills in a card that is already on screen.
            if let route = await self.enrichment.route(callsign: s.callsign) {
                self.popups.attachRoute(
                    operatorName: route.airline,
                    route: route.isComplete
                        ? "\(route.origin!.shortName) → \(route.destination!.shortName)" : nil,
                    to: s.id)
            }

            // The photo needs a registration lookup and then an image fetch,
            // which routinely outlives the aircraft. Strictly an enhancement.
            var registration = s.registration
            if registration == nil {
                registration = await self.enrichment.aircraft(hex: s.id)?.registration
            }
            if let registration,
               let photo = await self.enrichment.photo(registration: registration) {
                self.popups.attachPhoto(photo.thumbnailURL, to: s.id)
            }
        }
    }

    private func notify(_ s: Sighting, _ interest: Interest) {
        let obstruction = conditions?.obstruction(altitudeFeet: s.altitudeFeet, policy: policy)
        Task { [weak self] in
            guard let self else { return }
            // A route makes the alert far better, but must never hold it up.
            let route = await Self.withDeadline(seconds: 2) {
                await self.enrichment.route(callsign: s.callsign)
            }
            self.post(s, interest, route: route, obstruction: obstruction)
        }
    }

    /// Races a lookup against a deadline so a slow third party cannot delay an
    /// alert whose whole value is timeliness.
    private static func withDeadline<T>(seconds: Double,
                                        _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func post(_ s: Sighting, _ interest: Interest,
                      route: RouteInfo?, obstruction: String?) {
        let presentation = alertPresentation(for: s, interest: interest,
                                             route: route, obstruction: obstruction)
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: s.id, content: content, trigger: nil))
    }

    /// Shows a popup for the nearest aircraft, bypassing the budget and the
    /// presence check but nothing else — the card is built by the same code path
    /// a real alert uses, so what you see here is what you would get.
    func showTestPopup() {
        guard let observed = nearest.first else { return }
        let s = observed.sighting
        let interest = scorer.score(s)
            ?? Interest(category: .rare, score: 100, reason: "test popup")
        deliverPopup(s, interest)
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "SkyGlance test"
        content.body = "If you can read this, notification delivery works."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "test-\(Int(Date().timeIntervalSince1970))",
                                  content: content, trigger: nil))
    }
}
