import OverheadKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: SkyModel
    @State private var showingSources = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // "Not set up yet" and "quiet sky" used to render identically. They are
        // opposite situations and only one of them is the user's to fix.
        if let observer = model.observer {
            configured(observer: observer)
        } else {
            needsSetup
        }
    }

    private var needsSetup: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("SkyGlance doesn't know where you are").font(.headline)
            Text("It can't tell you what's overhead until it does.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set My Location") { openWindow(id: SkyGlanceApp.setupWindowID) }
                .buttonStyle(.borderedProminent)
            Button("Quit SkyGlance") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(24)
        .frame(width: 356)
    }

    private func configured(observer: Coordinate) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Everything nearby goes on the dome — including what you can't see,
            // drawn hollow — so the shaded wedge explains itself.
            SkyDomeView(observed: model.domeContents, profile: model.viewingProfile,
                        observer: observer, capturedAt: model.lastUpdate,
                        selection: model.selectedID, onSelect: { model.select($0) })
                .frame(height: 200)
                .padding(.vertical, 4)
            Divider()
            // Selecting swaps the list for detail; the dome stays put above so
            // you never lose sight of where the thing actually is. A minimum
            // height keeps the panel from jumping as the two swap.
            ZStack {
                if let selected = model.selected {
                    DetailCard(observed: selected, detail: model.detail,
                               isLoading: model.isLoadingDetail,
                               onBack: { model.select(nil) })
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)))
                } else {
                    lists
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .frame(minHeight: 168, alignment: .top)
            .clipped()
            .animation(.snappy(duration: 0.28), value: model.selectedID)
            Divider()
            footer
        }
        .frame(width: 356)
        .sheet(isPresented: $showingSources) {
            DataSourcesSheet(isPresented: $showingSources)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if let h = model.headline {
                Text(headlineTitle(h.sighting)).font(.headline)
                    .lineLimit(1).truncationMode(.tail)
                Text(headlineDetail(h.sighting)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(model.isStale ? "Showing older data" : "Nothing worth looking at")
                    .font(.headline)
                Text(model.totalCount == 0
                     ? "No aircraft in range"
                     : "\(model.totalCount) aircraft nearby, none in view overhead")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        // The headline changes on its own every few seconds; a crossfade makes
        // that read as the sky moving rather than as the panel glitching.
        .animation(.smooth(duration: 0.35), value: model.headline?.id)
        .animation(.smooth(duration: 0.35), value: model.totalCount)
    }

    private func headlineTitle(_ s: Sighting) -> String {
        // `desc` can be "BOMBARDIER BD-100 Challenger 350", which overflows the
        // title and makes the panel reflow. Keep it to the recognisable part.
        let what = Self.shortName(s)
        return s.isOverhead ? "\(what) overhead" : "\(what) coming over"
    }

    static func shortName(_ s: Sighting) -> String {
        guard let desc = s.description, !desc.isEmpty else { return s.typeCode ?? s.label }
        let words = desc.split(separator: " ")
        // Drop a leading all-caps manufacturer token: "AIRBUS A-320" -> "A-320".
        if words.count > 1, words[0].allSatisfy({ $0.isUppercase || $0 == "-" }) {
            return words.dropFirst().joined(separator: " ")
        }
        return desc
    }

    private func headlineDetail(_ s: Sighting) -> String {
        var parts = ["Look \(s.lookDirection)", "\(Int(s.elevationDegrees))° up"]
        if let cpa = s.closestApproach, !s.isOverhead, cpa.isApproaching {
            parts.insert("in \(Int(cpa.secondsAway))s", at: 1)
        }
        if s.altitudeFeet > 0 {
            parts.append("\((Int(s.altitudeFeet) / 100 * 100).formatted()) ft")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Lists

    /// A glanceable panel should never scroll. Cap the total rows and let the
    /// priority order (overhead, then inbound, then merely nearby) decide what
    /// survives — that is a more useful editorial choice than a scrollbar.
    private var lists: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleSections.enumerated()), id: \.offset) { _, s in
                section(s.title, s.rows, style: s.style)
            }
            if visibleSections.isEmpty {
                Text("No aircraft in range")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            }
        }
        .padding(.vertical, 4)
    }

    private struct Section {
        let title: String
        let rows: [Observed]
        let style: Sighting.DescriptionStyle
    }

    private static let maximumRows = 7

    /// Sections in priority order, trimmed so the panel keeps a stable height.
    private var visibleSections: [Section] {
        var budget = Self.maximumRows
        var seen = Set<String>()
        var result: [Section] = []
        let candidates: [(String, [Observed], Sighting.DescriptionStyle)] = [
            ("Overhead now", model.overhead, .elevation),
            ("Overhead within 90s", model.inbound, .approach),
            ("Nearest", model.nearest, .proximity),
        ]
        for (title, rows, style) in candidates {
            guard budget > 0 else { break }
            let fresh = rows.filter { seen.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            let taken = Array(fresh.prefix(budget))
            budget -= taken.count
            result.append(Section(title: title, rows: taken, style: style))
        }
        return result
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [Observed],
                         style: Sighting.DescriptionStyle) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(rows) { row in
                AircraftRow(observed: row, style: style, isSelected: model.selectedID == row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(model.selectedID == row.id ? nil : row.id) }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let c = model.conditions {
                    Image(systemName: c.isDaylight ? "sun.max" : "moon")
                    Text(c.summary)
                }
                Spacer()
                Text("\(model.totalCount) aircraft").foregroundStyle(.secondary)
            }
            .font(.caption)

            // A denied notification permission is silent otherwise: the count
            // below keeps ticking up for alerts macOS never delivered.
            if model.notificationsAllowed == false {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                    Text("Notifications are off — enable them in System Settings")
                        .lineLimit(2)
                }
                .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "bell")
                    Text("\(model.alertsToday)/\(model.policy.maximumPerDay) alerts today")
                    if let reason = model.lastSuppression {
                        Text("· held: \(reason)").foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Text(model.sources.isEmpty ? "no sources" : model.sources.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            HStack {
                Button("Settings…") { openWindow(id: SkyGlanceApp.setupWindowID) }
                Button("Refresh") { model.refreshNow() }
                Spacer()
                Menu {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { _ in model.toggleLaunchAtLogin() }))
                    Button("Send Test Notification") { model.sendTestNotification() }
                    Divider()
                    Button("Data Sources & Licences…") { showingSources = true }
                    Divider()
                    Button("Quit SkyGlance") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// One aircraft. Out-of-arc rows are dimmed and marked rather than hidden, so you
/// keep awareness of nearby traffic without ever being told to look at it.
struct AircraftRow: View {
    let observed: Observed
    let style: Sighting.DescriptionStyle
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Matches the dome: filled and tinted if you can look at it, hollow
            // and grey if it is behind you.
            Circle()
                .fill(observed.isVisible ? Color.accentColor : Color.clear)
                .overlay(Circle().stroke(Color.secondary.opacity(0.5),
                                         lineWidth: observed.isVisible ? 0 : 1))
                .frame(width: 6, height: 6)

            Text(observed.sighting.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 62, alignment: .leading)

            Text(observed.sighting.typeCode ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Text(measurement)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(observed.sighting.lookDirection)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(observed.isVisible ? .primary : .tertiary)
                .frame(width: 30, alignment: .trailing)

            if !observed.isVisible {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help("Outside your view — behind you")
            }
        }
        .opacity(observed.isVisible ? 1 : 0.45)
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(rowBackground)
        // The rows are tappable but look like text; a hover tint is the only
        // thing that says so before you click.
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var rowBackground: Color {
        if isSelected { return .accentColor.opacity(0.16) }
        if isHovered { return .primary.opacity(0.06) }
        return .clear
    }

    /// Altitude is the whole point of "big and low", so it is always shown.
    private var measurement: String {
        let s = observed.sighting
        let altitude = s.altitudeFeet > 0 ? "\(Int(s.altitudeFeet / 100) * 100)ft" : "—"
        switch style {
        case .elevation:
            return "\(Int(s.elevationDegrees))° up · \(altitude)"
        case .approach:
            if let cpa = s.closestApproach, cpa.isApproaching {
                return "\(Int(cpa.secondsAway))s · \(Int(cpa.elevationDegrees))° · \(altitude)"
            }
            return "\(Int(s.elevationDegrees))° up · \(altitude)"
        case .proximity:
            return String(format: "%.1f km · %d° · %@", s.slantRangeKm,
                          Int(s.elevationDegrees), altitude)
        }
    }
}

/// ODbL requires that adsb.lol be credited wherever its data is shown, and
/// planespotters requires the photographer credit (which `DetailCard` renders).
/// This is a licence condition, not an about box.
struct DataSourcesSheet: View {
    @Binding var isPresented: Bool

    private struct Source {
        let name: String, url: String, gives: String, terms: String
    }

    private static let sources: [Source] = [
        .init(name: "adsb.lol", url: "https://www.adsb.lol",
              gives: "Live aircraft positions",
              terms: "Open Database License (ODbL) 1.0"),
        .init(name: "airplanes.live", url: "https://airplanes.live",
              gives: "Live aircraft positions",
              terms: "Free, non-commercial"),
        .init(name: "adsb.fi", url: "https://adsb.fi",
              gives: "Live aircraft positions",
              terms: "Free, community-run"),
        .init(name: "adsbdb.com", url: "https://www.adsbdb.com",
              gives: "Aircraft types and flight routes",
              terms: "Free, volunteer-run"),
        .init(name: "hexdb.io", url: "https://hexdb.io",
              gives: "Aircraft and route fallback",
              terms: "Free, volunteer-run"),
        .init(name: "planespotters.net", url: "https://www.planespotters.net",
              gives: "Aircraft photographs",
              terms: "Photographs remain the property of their photographers"),
        .init(name: "Open-Meteo", url: "https://open-meteo.com",
              gives: "Cloud cover and daylight",
              terms: "Free for non-commercial use"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Data sources").font(.title3).bold()
                Text("Every one of these is free and run by volunteers. None of them charges SkyGlance anything, and none of them owes you a service.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Self.sources, id: \.name) { source in
                    VStack(alignment: .leading, spacing: 1) {
                        Link(source.name, destination: URL(string: source.url)!)
                            .font(.system(size: 12, weight: .medium))
                        Text(source.gives).font(.caption).foregroundStyle(.secondary)
                        Text(source.terms).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            Text("SkyGlance itself is MIT-licensed and open source.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Link("Source code", destination: URL(
                    string: "https://github.com/darshjoshi/skyglance-mac")!)
                    .font(.caption)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// What we know about one aircraft. Roughly one in seven has no route and one in
/// seven no photo, so every block is independently optional — a missing field
/// disappears rather than leaving a hole.
struct DetailCard: View {
    let observed: Observed
    let detail: AircraftDetail?
    let isLoading: Bool
    var onBack: () -> Void

    private var sighting: Sighting { observed.sighting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            if let photo = detail?.photo {
                AsyncImage(url: URL(string: photo.thumbnailURL)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 90)
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)

                if let route = detail?.route, route.isComplete {
                    HStack(spacing: 4) {
                        Text(route.origin!.shortName)
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(route.destination!.shortName)
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                }

                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(position).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                if detail != nil, detail?.isEmpty == true, !isLoading {
                    Text("No further details found")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            HStack {
                // Attribution is a licence condition of the photo, not decoration.
                if let photo = detail?.photo {
                    Text("photo © \(photo.photographer)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button("Track ↗") {
                    if let url = URL(string: "https://globe.adsb.lol/?icao=\(sighting.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if let airline = detail?.route?.airline { return airline }
        if let owner = detail?.info?.owner { return owner }
        return sighting.label
    }

    private var subtitle: String {
        var parts: [String] = []
        if let type = detail?.info?.type ?? sighting.description ?? sighting.typeCode {
            parts.append(type)
        }
        if let registration = sighting.registration ?? detail?.info?.registration {
            parts.append(registration)
        }
        if sighting.callsign != nil, detail?.route?.airline != nil {
            parts.append(sighting.label)
        }
        return parts.joined(separator: " · ")
    }

    private var position: String {
        var parts: [String] = []
        if sighting.altitudeFeet > 0 {
            parts.append("\((Int(sighting.altitudeFeet) / 100 * 100).formatted()) ft")
        }
        parts.append(String(format: "%.1f km", sighting.slantRangeKm))
        parts.append("\(Int(sighting.elevationDegrees))° up")
        parts.append(observed.isVisible ? sighting.lookDirection
                                        : "\(sighting.lookDirection) — behind you")
        return parts.joined(separator: " · ")
    }
}
