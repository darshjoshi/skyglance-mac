import OverheadKit
import SwiftUI

/// The sky as you actually look at it: centre is straight up, the rim is the
/// horizon, north is up. A top-down map answers "where is it going"; this
/// answers "where do I point my face", which is the question the app exists for.
///
/// The radial scale is deliberately not linear — see `SkyProjection`. Everything
/// this location ever sees sits within 10° of the horizon, so the horizon band
/// gets the space instead of a zenith that is empty all day.
struct SkyDomeView: View {
    let observed: [Observed]
    let profile: ViewingProfile
    let observer: Coordinate
    let capturedAt: Date?
    let selection: String?
    var onSelect: (String?) -> Void

    @Environment(\.colorScheme) private var scheme

    /// Longest a position is carried forward. If the feed stalls, the sky should
    /// freeze rather than fly apart — a still dome reads as "waiting", a
    /// scattering one reads as "working".
    private static let maximumDrift: Double = 8
    /// Trails are drawn to a target *length* rather than a fixed time window.
    /// Measured against live traffic, a 60 s window gives tails from 1.5 pt to
    /// 28 pt depending on distance and geometry — the short ones are invisible
    /// and the long ones wrap the dome. Walking back through history until the
    /// tail is this long instead gives every aircraft a readable one.
    private static let trailLength: CGFloat = 26
    private static let fadeIn: Double = 0.5
    private static let fadeOut: Double = 1.0
    /// Labelling everything turns the dome into soup.
    private static let maximumLabels = 4

    var body: some View {
        // .animation ticks with the display, so the sky moves continuously rather
        // than jumping every three seconds. It only runs while the panel is open:
        // .menuBarExtraStyle(.window) does not instantiate this view until then.
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(&context, size: size, now: timeline.date)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(nil) }
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let visible = observed.filter(\.isVisible).count
        return "Sky view. \(observed.count) aircraft nearby, \(visible) inside your view."
    }

    // MARK: - Frame

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date) {
        // Leave room outside the horizon ring for the compass letters.
        let radius = min(size.width, size.height) / 2 - 16
        guard radius > 20 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let elapsed = min(Self.maximumDrift,
                          max(0, now.timeIntervalSince(capturedAt ?? now)))

        drawSkyDisc(&context, centre: centre, radius: radius)
        drawVisibleWedge(&context, centre: centre, radius: radius)
        drawGrid(&context, centre: centre, radius: radius)
        drawCompassLabels(&context, centre: centre, radius: radius)

        // Position everything once, then draw in layers so trails never cover a
        // glyph and labels never sit under a trail.
        let placed = observed.map { o -> Placed in
            let p = o.sighting.skyPoint(from: observer, after: elapsed)
            return Placed(observed: o,
                          point: project(p, centre: centre, radius: radius),
                          skyPoint: p,
                          opacity: opacity(o, now: now))
        }
        for p in placed where wantsTrail(p) {
            drawTrail(&context, p, centre: centre, radius: radius)
        }
        for p in placed { drawGlyph(&context, p) }
        drawLabels(&context, placed, centre: centre, radius: radius)
    }

    private struct Placed {
        let observed: Observed
        let point: CGPoint
        let skyPoint: SkyPoint
        let opacity: Double
        var sighting: Sighting { observed.sighting }
    }

    /// Bearing and elevation onto the disc. North is up, east is right.
    private func project(_ p: SkyPoint, centre: CGPoint, radius: CGFloat) -> CGPoint {
        let r = radius * CGFloat(SkyProjection.radiusFraction(elevationDegrees: p.elevationDegrees))
        let a = p.bearingDegrees * .pi / 180
        return CGPoint(x: centre.x + r * CGFloat(sin(a)),
                       y: centre.y - r * CGFloat(cos(a)))
    }

    /// Aircraft fade in and out rather than popping, so a busy sky doesn't
    /// flicker every poll.
    private func opacity(_ o: Observed, now: Date) -> Double {
        if let vanished = o.vanishedAt {
            return max(0, 1 - now.timeIntervalSince(vanished) / Self.fadeOut)
        }
        return min(1, max(0, now.timeIntervalSince(o.appearedAt) / Self.fadeIn))
    }

    // MARK: - Backdrop

    private func drawSkyDisc(_ context: inout GraphicsContext,
                             centre: CGPoint, radius: CGFloat) {
        let disc = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
        // Darker overhead, lighter toward the horizon — the way the sky actually
        // looks, and it stops the disc reading as a flat hole in the panel.
        context.fill(disc, with: .radialGradient(
            Gradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.02)]),
            center: centre, startRadius: 0, endRadius: radius))
    }

    /// The arc you can actually see. Shading it keeps the visibility rule visible
    /// rather than making it a hidden filter that silently drops aircraft.
    private func drawVisibleWedge(_ context: inout GraphicsContext,
                                  centre: CGPoint, radius: CGFloat) {
        guard profile.bearingHalfWidth < 180 else { return }
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: radius,
                    startAngle: .degrees(profile.bearingCenter - profile.bearingHalfWidth - 90),
                    endAngle: .degrees(profile.bearingCenter + profile.bearingHalfWidth - 90),
                    clockwise: false)
        path.closeSubpath()
        // Kept deliberately faint. This wedge can span 220°, so anything stronger
        // stops reading as "the part you can see" and starts reading as the
        // subject of the picture — which is the aircraft.
        context.fill(path, with: .radialGradient(
            Gradient(colors: [.accentColor.opacity(0.02), .accentColor.opacity(0.11)]),
            center: centre, startRadius: 0, endRadius: radius))
        context.stroke(path, with: .color(.accentColor.opacity(0.28)), lineWidth: 1)
    }

    private func drawGrid(_ context: inout GraphicsContext,
                          centre: CGPoint, radius: CGFloat) {
        let horizon = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                             width: radius * 2, height: radius * 2))
        context.stroke(horizon, with: .color(.secondary.opacity(0.55)), lineWidth: 1)

        for (index, elevation) in SkyProjection.ringElevations.enumerated() {
            let r = radius * CGFloat(SkyProjection.radiusFraction(elevationDegrees: elevation))
            let ring = Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                              width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(.secondary.opacity(0.22)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            // Ring labels go opposite the wedge — the emptiest part of the sky is
            // the only place chrome can sit without covering an aircraft — and
            // fan alternately either side of it. Stacked along one radius the
            // inner rings are only ~13 pt apart and the text runs together.
            let a = (profile.bearingCenter + 180 + (index.isMultiple(of: 2) ? 34 : -34))
                * .pi / 180
            var label = context.resolve(Text("\(Int(elevation))°")
                .font(.system(size: 8, weight: .medium)))
            label.shading = .color(.secondary.opacity(0.55))
            context.draw(label, at: CGPoint(x: centre.x + r * CGFloat(sin(a)),
                                            y: centre.y - r * CGFloat(cos(a))))
        }

        // Zenith marker: straight up.
        let dot = CGRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3)
        context.fill(Path(ellipseIn: dot), with: .color(.secondary.opacity(0.5)))
    }

    private func drawCompassLabels(_ context: inout GraphicsContext,
                                   centre: CGPoint, radius: CGFloat) {
        for (label, bearing) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            let a = bearing * .pi / 180
            // Explicitly outside the horizon ring. Placing these by elevation put
            // them exactly on the rim once the projection stopped being linear —
            // which is where every aircraft now lives.
            let r = radius + 9
            var resolved = context.resolve(Text(label)
                .font(.system(size: 9, weight: .semibold)))
            resolved.shading = .color(.secondary)
            context.draw(resolved, at: CGPoint(x: centre.x + r * CGFloat(sin(a)),
                                               y: centre.y - r * CGFloat(cos(a))))
        }
    }

    // MARK: - Aircraft

    /// Trails only for what you can look at, plus whatever is selected. Forty
    /// tails is noise, and it also keeps the per-frame geometry cheap.
    private func wantsTrail(_ p: Placed) -> Bool {
        p.observed.isVisible || selection == p.sighting.id
    }

    /// Where it has actually been. The head is the live extrapolated position so
    /// the tail stays attached to the moving glyph; everything behind it is
    /// recorded, one point per poll, walked backwards until the trail is long
    /// enough to read. An aircraft that only just appeared gets a short trail,
    /// which is the truth about it.
    private func drawTrail(_ context: inout GraphicsContext, _ p: Placed,
                           centre: CGPoint, radius: CGFloat) {
        let history = p.observed.trail
        guard history.count >= 2 else { return }
        let tint = colour(for: p.sighting)
        var previous = p.point
        var covered: CGFloat = 0

        for point in history.reversed() {
            let here = project(point, centre: centre, radius: radius)
            let length = hypot(here.x - previous.x, here.y - previous.y)
            // Skip samples that did not move: stroking a zero-length segment with
            // a round cap leaves a dot, and a stationary aircraft would grow a
            // string of beads.
            guard length > 0.2 else { previous = here; continue }

            var segment = Path()
            segment.move(to: previous)
            segment.addLine(to: here)
            // Fades and thins with distance travelled, not with sample count, so
            // a long trail and a short one both fade all the way out.
            let t = 1 - covered / Self.trailLength
            // Never as strong as the glyph: the aircraft is the subject and the
            // trail is context. At equal weight the two merge into one blob.
            context.stroke(segment,
                           with: .color(tint.opacity(0.5 * pow(t, 1.4) * p.opacity)),
                           style: StrokeStyle(lineWidth: 0.7 + 1.7 * t, lineCap: .round))

            covered += length
            previous = here
            if covered >= Self.trailLength { return }
        }
    }

    private func drawGlyph(_ context: inout GraphicsContext, _ p: Placed) {
        let s = p.sighting
        let size = markerSize(for: s)
        let isSelected = selection == s.id
        let tint = colour(for: s)

        if isSelected {
            let halo = CGRect(x: p.point.x - size - 5, y: p.point.y - size - 5,
                              width: (size + 5) * 2, height: (size + 5) * 2)
            context.stroke(Path(ellipseIn: halo),
                           with: .color(tint.opacity(0.8 * p.opacity)), lineWidth: 1.5)
        }

        // Heading is the single most useful thing about an aircraft you are about
        // to look for, so the marker carries it. Without a track there is nothing
        // honest to point, so it stays a dot.
        guard let track = s.trackDegrees else {
            let rect = CGRect(x: p.point.x - size / 2, y: p.point.y - size / 2,
                              width: size, height: size)
            if p.observed.isVisible {
                context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(p.opacity)))
            } else {
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.secondary.opacity(0.4 * p.opacity)), lineWidth: 1)
            }
            return
        }

        var glyph = context
        glyph.translateBy(x: p.point.x, y: p.point.y)
        glyph.rotate(by: .degrees(track))
        let shape = Self.dart(size: size)

        // Out-of-arc aircraft stay on the dome so you keep awareness, but they are
        // hollow and faint — clearly "not for you to look at".
        if p.observed.isVisible {
            glyph.fill(shape, with: .color(tint.opacity(p.opacity)))
            glyph.stroke(shape, with: .color(.black.opacity(0.35 * p.opacity)),
                         lineWidth: 0.5)
        } else {
            glyph.stroke(shape, with: .color(.secondary.opacity(0.45 * p.opacity)),
                         lineWidth: 1)
        }
    }

    /// A dart pointing north, rotated into the track. Drawn rather than an SF
    /// Symbol so the silhouette stays crisp at 5 pt.
    /// Internal rather than private: the popup card draws the same silhouette,
    /// and two hand-drawn darts would drift apart.
    static func dart(size: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -size))
        p.addLine(to: CGPoint(x: size * 0.66, y: size * 0.74))
        p.addLine(to: CGPoint(x: 0, y: size * 0.34))
        p.addLine(to: CGPoint(x: -size * 0.66, y: size * 0.74))
        p.closeSubpath()
        return p
    }

    // MARK: - Labels

    /// Callsigns on the few that matter. Everything else would collide with
    /// everything else at this scale, and an unreadable label is worse than none.
    private func drawLabels(_ context: inout GraphicsContext, _ placed: [Placed],
                            centre: CGPoint, radius: CGFloat) {
        let candidates = placed
            // A label on something mid-fade points at an aircraft that is not
            // really there yet, or no longer is.
            .filter { ($0.observed.isVisible || selection == $0.sighting.id) && $0.opacity > 0.6 }
            .sorted { priority($0) > priority($1) }
        let everyGlyph = placed.map(\.point)

        var placedBoxes: [CGRect] = []
        for p in candidates where placedBoxes.count < Self.maximumLabels {
            // Right of the glyph normally; flip to the left in the outer right of
            // the disc so the text never runs off the canvas.
            let flip = p.point.x > centre.x + radius * 0.4
            let anchor = CGPoint(x: p.point.x + (flip ? -10 : 10), y: p.point.y)

            var text = context.resolve(Text(p.sighting.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced)))
            text.shading = .color(selection == p.sighting.id ? .primary : .secondary)
            let measured = text.measure(in: CGSize(width: radius * 2, height: 20))
            let box = CGRect(x: anchor.x - (flip ? measured.width + 3 : 3),
                             y: anchor.y - measured.height / 2 - 1,
                             width: measured.width + 6, height: measured.height + 2)

            // Real rectangle overlap, not anchor distance — a proportional-width
            // callsign is far wider than the gap between two glyphs, so distance
            // between anchors said "clear" while the pills sat on top of each
            // other.
            guard placedBoxes.allSatisfy({ !$0.insetBy(dx: -3, dy: -2).intersects(box) }),
                  // and never bury another aircraft under a label
                  !everyGlyph.contains(where: { $0 != p.point && box.contains($0) })
            else { continue }
            placedBoxes.append(box)

            // An opaque pill, not a tint: over a trail or a neighbouring glyph,
            // translucent grey on grey is unreadable. Keyed to the colour scheme
            // rather than an NSColor, because NSColor resolves against the
            // drawing appearance and would come out light on a dark panel.
            context.fill(Path(roundedRect: box, cornerRadius: 3),
                         with: .color(scheme == .dark
                                      ? Color(white: 0.16).opacity(0.92)
                                      : Color(white: 1.0).opacity(0.92)))
            context.stroke(Path(roundedRect: box, cornerRadius: 3),
                           with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            context.draw(text, at: anchor, anchor: flip ? .trailing : .leading)
        }
    }

    /// Overhead beats inbound beats merely nearby, and anything unusual jumps the
    /// queue — the same ordering the panel's list uses.
    private func priority(_ p: Placed) -> Double {
        let s = p.sighting
        var score = s.elevationDegrees
        if selection == s.id { score += 1000 }
        if s.hasEmergency { score += 500 }
        if let t = s.typeCode, rareTypeCodes.contains(t.uppercased()) { score += 200 }
        if s.isMilitary { score += 100 }
        if let cpa = s.closestApproach, cpa.isApproaching { score += 50 }
        return score
    }

    // MARK: - Appearance

    /// Marker size tracks physical size, so an airliner reads bigger than a Cessna.
    private func markerSize(for s: Sighting) -> CGFloat {
        if s.isLarge { return 5.5 }
        if s.isRotorcraft { return 4.5 }
        return 3.5
    }

    private func colour(for s: Sighting) -> Color { Self.tint(for: s) }

    /// Shared with the popup card so an aircraft is the same colour wherever it
    /// appears — a purple dart on the dome and a purple dart in the card are the
    /// same aircraft, and that should not need explaining.
    static func tint(for s: Sighting) -> Color {
        if s.hasEmergency { return .red }
        if let t = s.typeCode, rareTypeCodes.contains(t.uppercased()) { return .purple }
        if s.isMilitary { return .orange }
        if s.isLarge { return .accentColor }
        if s.isRotorcraft { return .teal }
        // .secondary resolves nearly black in light mode, which made an unknown
        // aircraft the heaviest thing on the dome — the opposite of the truth.
        return .gray
    }
}
