import CoreLocation
import OverheadKit
import SwiftUI

/// One-shot location lookup. Deliberately not a long-lived manager: the app needs
/// a coordinate once, at setup, and has no reason to keep watching where you are.
@MainActor
final class OneShotLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case asking
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let manager = CLLocationManager()
    private var completion: ((Coordinate?) -> Void)?
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer  // a house, not a doorstep
    }

    func request(_ completion: @escaping (Coordinate?) -> Void) {
        guard CLLocationManager.locationServicesEnabled() else {
            return fail("Location Services is turned off in System Settings.", completion)
        }
        self.completion = completion
        state = .asking

        switch manager.authorizationStatus {
        case .notDetermined:
            // Only ask. `requestWhenInUseAuthorization` is asynchronous, so a
            // `requestLocation()` on the next line runs while the status is
            // still undetermined and fails instantly with kCLErrorDenied —
            // reporting "access was denied" for a question the user was never
            // given the chance to answer. Wait for the delegate instead.
            manager.requestWhenInUseAuthorization()
            waitForPermission()
        case .denied, .restricted:
            fail(Self.deniedMessage, nil)
        default:
            locate()
        }
    }

    /// macOS does not always answer `requestWhenInUseAuthorization` at all: an
    /// app signed ad-hoc, with no Team ID, is never registered with Location
    /// Services, so no dialog appears and no callback ever arrives. Measured on
    /// such a build, the status stays `.notDetermined` indefinitely.
    ///
    /// So this stops *blocking* after a few seconds rather than declaring
    /// failure — the request stays live, because on a properly signed build the
    /// dialog is real and someone may take a while to read it. Answer it later
    /// and the field still fills in.
    private func waitForPermission() {
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.completion != nil,
                  self.manager.authorizationStatus == .notDetermined else { return }
            self.state = .failed("macOS hasn't shown a permission dialog. If one appears, "
                                 + "answer it — otherwise switch SkyGlance on in Location "
                                 + "Services, or type your coordinates below.")
        }
    }

    /// Split out because it is reached two ways: immediately when permission was
    /// already granted, and from the authorisation callback once it is.
    private func locate() {
        manager.requestLocation()
        // A fix can hang indefinitely. Setup must never become unfinishable, so
        // give up and hand the user back to the text field. Started here rather
        // than in `request` so that time spent reading the permission dialog
        // does not count against it.
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.completion != nil else { return }
            self.fail("Couldn't get your location in time — type it in instead.", nil)
        }
    }

    static let deniedMessage = "Location access is off for SkyGlance. Switch it on, "
        + "then click Use My Location again — or just type your coordinates below."

    private func fail(_ message: String, _ completion: ((Coordinate?) -> Void)?) {
        state = .failed(message)
        (completion ?? self.completion)?(nil)
        self.completion = nil
        timeout?.cancel()
    }

    private func finish(_ coordinate: Coordinate) {
        state = .idle
        completion?(coordinate)
        completion = nil
        timeout?.cancel()
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let found = l.last else { return }
        Task { @MainActor in
            finish(Coordinate(latitude: found.coordinate.latitude,
                              longitude: found.coordinate.longitude))
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard completion != nil else { return }
            let denied = (error as? CLError)?.code == .denied
            fail(denied ? Self.deniedMessage
                        : "Couldn't get your location — type it in instead.", nil)
        }
    }

    /// Fires when the user answers the permission dialog — and once on startup
    /// with the current status, which is why this only acts mid-request.
    /// Without it the app could never learn that permission had been granted.
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            guard completion != nil else { return }
            switch m.authorizationStatus {
            case .notDetermined:
                break  // dialog still on screen; the user has not answered yet
            case .denied, .restricted:
                fail(Self.deniedMessage, nil)
            default:
                locate()
            }
        }
    }
}

/// Where you are and what you can see. Used for both first-run setup and for
/// changing your mind later, because they ask exactly the same two questions.
struct SetupView: View {
    @ObservedObject var model: SkyModel
    /// Seeds the coordinate field without touching the saved location. Only
    /// `--render-setup` passes it, so a screenshot can be taken over a chosen
    /// place rather than over whoever is running the app.
    var seedText: String = ""
    /// First run gets a welcome and asks for notification permission at the end.
    let isFirstRun: Bool
    var onDone: () -> Void

    @StateObject private var locator = OneShotLocation()
    @State private var text = ""
    @State private var problem: String?
    @State private var seesAllRound = true
    @State private var facing = 90.0
    @State private var halfWidth = 100.0
    @State private var coverage: SkyModel.Coverage?
    @State private var isCheckingCoverage = false
    /// Cancelled and replaced on every edit, so a slow answer for a coordinate
    /// the user has already typed past can never overwrite a newer one.
    @State private var coverageProbe: Task<Void, Never>?
    /// Set immediately before `text` is written by code rather than typed, and
    /// cleared by the very next `onChange`. `onChange(of:)` cannot tell the two
    /// apart, so without this the debounced check would cancel and replace the
    /// answer `onAppear` had just arranged — which is why the instant check it
    /// asks for never actually happened.
    @State private var textWasSetProgrammatically = false

    private static let compass: [(String, Double)] = [
        ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
        ("S", 180), ("SW", 225), ("W", 270), ("NW", 315),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isFirstRun ? "Where do you watch the sky?" : "Your sky")
                    .font(.title2).bold()
                Text(isFirstRun
                     ? "SkyGlance shows what is flying over you right now. It needs one thing first."
                     : "Change where you are, or what you can see from there.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            location
            Divider()
            arc

            HStack {
                if !isFirstRun {
                    Button("Cancel") { onDone() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(isFirstRun ? "Start Watching" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if !seedText.isEmpty {
                textWasSetProgrammatically = true
                text = seedText
                checkCoverage(after: .zero)
            } else if let existing = model.observer {
                textWasSetProgrammatically = true
                text = LocationInput.format(existing)
                // Already-chosen coordinates are not being typed, so there is
                // nothing to debounce and no reason to make someone wait — and
                // for the saved location the poll loop has already asked, so
                // there is nothing to send either.
                if let known = model.liveCoverageForObserver {
                    coverage = known
                } else {
                    checkCoverage(after: .zero)
                }
            }
            let profile = model.viewingProfile
            seesAllRound = profile.bearingHalfWidth >= 180
            if !seesAllRound {
                facing = profile.bearingCenter
                halfWidth = profile.bearingHalfWidth
            }
        }
        .onChange(of: text) { _ in
            if textWasSetProgrammatically { textWasSetProgrammatically = false }
            else { checkCoverage() }
        }
        .onDisappear { coverageProbe?.cancel() }
    }

    // MARK: - Location

    /// Deep-links to Privacy & Security › Location Services. The anchor after
    /// the `?` is what selects that specific pane; without it macOS opens the
    /// top of Privacy & Security and the user still has to hunt.
    static func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:"
                            + "com.apple.settings.PrivacySecurity.extension"
                            + "?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                problem = nil
                locator.request { found in
                    if let found { text = LocationInput.format(found) }
                }
            } label: {
                HStack(spacing: 6) {
                    if locator.state == .asking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "location.fill")
                    }
                    Text(locator.state == .asking ? "Locating…" : "Use My Location")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(locator.state == .asking)

            Text("or enter it yourself")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField(LocationInput.example, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(save)

            // Location failures are stated, never silent — this button can fail
            // outright on an unsigned build and the text field is the way through.
            if case .failed(let why) = locator.state {
                VStack(alignment: .leading, spacing: 6) {
                    Label(why, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Every route out of a location failure runs through this
                    // pane, and it is buried four levels into System Settings.
                    // Naming it without offering to open it just moves the
                    // problem onto the user.
                    Button("Open Location Settings…") { Self.openLocationSettings() }
                        .font(.caption)
                        .buttonStyle(.link)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            coverageNote

            // This is the screen where someone hands over their location, so it
            // is the screen that has to say where it goes. Quiet, one line, no
            // dialog to dismiss — but never absent.
            Label("Rounded to about a kilometre before it is sent to the flight "
                  + "feeds. Your exact position stays on this Mac.",
                  systemImage: "lock.fill")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    // MARK: - Coverage

    /// The one thing about this app a person cannot discover by waiting: whether
    /// any receiver can hear the sky where they live. Shown here, while the
    /// coordinate is still being chosen, because it is the last moment the
    /// answer is useful — afterwards it is just an empty panel forever.
    @ViewBuilder
    private var coverageNote: some View {
        if isCheckingCoverage {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking what can be seen from there…")
            }
            .font(.caption).foregroundStyle(.secondary)
        } else if let coverage {
            switch coverage {
            case .live(let count):
                Label("\(count) aircraft over there right now.",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)

            // Stated plainly, and not as an error, because nothing is broken and
            // there is nothing to retry — it is a fact about the ground here.
            case .silent:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Nothing can be heard here.", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).bold()
                    Text("The flight feeds are volunteer-run receivers, and none of them "
                         + "cover this spot — so SkyGlance would show an empty sky however "
                         + "busy it really is. Somewhere closer to a city or an airport will "
                         + "work. You can still save this and look again later.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            case .unreachable:
                Label("Could not reach the flight feeds just now — which says nothing "
                      + "about coverage here.", systemImage: "exclamationmark.icloud")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Debounced: someone typing a coordinate produces a valid one several times
    /// on the way to the one they mean, and each would otherwise be a request to
    /// three volunteer services.
    private func checkCoverage(after delay: Duration = .milliseconds(700)) {
        coverageProbe?.cancel()
        guard case .success(let coordinate) = LocationInput.parse(text) else {
            coverage = nil
            isCheckingCoverage = false
            return
        }
        coverageProbe = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isCheckingCoverage = true
            let result = await model.coverage(at: coordinate)
            guard !Task.isCancelled else { return }
            isCheckingCoverage = false
            coverage = result
        }
    }

    // MARK: - Arc

    private var arc: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What can you see from there?").font(.headline)
            Picker("", selection: $seesAllRound) {
                Text("All around").tag(true)
                Text("One direction").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if seesAllRound {
                Text("Every aircraft nearby counts. Pick a direction if a building or hill blocks half your sky.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Picker("Facing", selection: $facing) {
                        ForEach(Self.compass, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .frame(width: 150)
                    Spacer()
                    Text("± \(Int(halfWidth))°").font(.caption).monospacedDigit()
                }
                Slider(value: $halfWidth, in: 30...170, step: 10)
                // The arc gates the menu bar headline and every alert, so what it
                // costs has to be visible at the moment you choose it.
                Text("Aircraft outside this arc still appear, dimmed, but never trigger an alert.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Save

    private func save() {
        switch LocationInput.parse(text) {
        case .failure(let why):
            problem = why.message
        case .success(let coordinate):
            problem = nil
            model.viewingProfile = seesAllRound
                ? .allSky
                : ViewingProfile(bearingCenter: facing, bearingHalfWidth: halfWidth)
            model.observer = coordinate
            if isFirstRun { model.requestNotificationPermission() }
            onDone()
        }
    }
}
