import Foundation

/// The trustworthy prediction window. Measured: straight-line extrapolation has a
/// 0.30 km median error at 60s but 5.98 km at 240s, where 77% of aircraft are more
/// than 2 km off. Promising anything beyond ~90s is lying. See OVER-MY-HOUSE.md.
public let trustedPredictionWindow: TimeInterval = 90

public enum Notability: Int, Comparable, Sendable {
    case routine = 0, notable = 1, rare = 2, urgent = 3
    public static func < (a: Notability, b: Notability) -> Bool { a.rawValue < b.rawValue }

    public var symbol: String {
        switch self {
        case .routine: return ""
        case .notable: return "★"
        case .rare: return "◆"
        case .urgent: return "!"
        }
    }
}

/// Types worth walking outside for. Deliberately short — the point is rarity.
public let rareTypeCodes: Set<String> = [
    "A124", "A225",           // Antonov
    "A388",                   // A380
    "B748", "B741", "B742", "B743", "B744",   // 747
    "B52", "B1", "B2",        // heavy bombers
    "C5M", "C17",             // outsize military transport
    "CONC", "SR71", "U2",
    "SPIT", "LANC", "B17", "P51", "DC3", "DC6", "CVLT",  // warbirds and classics
]

public struct SkyState: Sendable {
    public let overheadNow: [Sighting]
    public let inboundSoon: [Sighting]
    public let nearest: [Sighting]
    public let capturedAt: Date
    public let isStale: Bool
    public let isDegraded: Bool
    public let error: String?
    public let sources: [String]

    public init(snapshot: Snapshot) {
        let all = snapshot.sightings

        self.overheadNow = all.filter(\.isOverhead)
            .sorted { $0.elevationDegrees > $1.elevationDegrees }

        self.inboundSoon = all
            .filter { s in
                guard !s.isOverhead, let cpa = s.closestApproach else { return false }
                return cpa.isApproaching
                    && cpa.secondsAway <= trustedPredictionWindow
                    && cpa.elevationDegrees >= 40
            }
            .sorted { ($0.closestApproach?.secondsAway ?? 0) < ($1.closestApproach?.secondsAway ?? 0) }

        self.nearest = all.sorted { $0.slantRangeKm < $1.slantRangeKm }
        self.capturedAt = snapshot.capturedAt
        self.isStale = snapshot.isStale
        self.isDegraded = snapshot.isDegraded
        self.error = snapshot.error
        self.sources = snapshot.contributingSources
    }

    /// The single thing worth putting in the menu bar.
    public var headline: Sighting? {
        overheadNow.first ?? inboundSoon.first
    }

    public var headlineText: String {
        guard let s = headline else {
            // A failure and a quiet sky must not look identical in the menu bar.
            if error != nil { return "⚠︎" }
            if isStale { return "—⏳" }
            return nearest.isEmpty ? "no contact" : "—"
        }
        let mark = notability(of: s).symbol
        let prefix = mark.isEmpty ? "" : "\(mark) "
        if s.isOverhead {
            return "\(prefix)\(s.typeCode ?? s.label) \(Int(s.elevationDegrees))°"
        }
        if let cpa = s.closestApproach {
            return "\(prefix)\(s.typeCode ?? s.label) \(Int(cpa.secondsAway))s"
        }
        return "\(prefix)\(s.label)"
    }
}

public func notability(of s: Sighting) -> Notability {
    if let type = s.typeCode, rareTypeCodes.contains(type.uppercased()) { return .rare }
    if s.altitudeFeet > 0 && s.altitudeFeet < 2000 && s.slantRangeKm < 15 { return .notable }
    return .routine
}

extension Sighting {
    /// How a row is written depends on which list it is in, not on whether the
    /// aircraft happens to have a closest-approach solution. Inferring the format
    /// leaks "in 15s" into the distance list, where it reads as an imminent
    /// flyover even when the closest approach is at 0° — i.e. landing, invisible.
    public enum DescriptionStyle {
        case elevation   // it is up there now
        case approach    // it will be up there shortly
        case proximity   // how far away it is
    }

    private var namePrefix: [String] {
        var parts = [label.padding(toLength: max(label.count, 8), withPad: " ", startingAt: 0)]
        if let typeCode { parts.append(typeCode) }
        return parts
    }

    public func describe(_ style: DescriptionStyle) -> String {
        var parts = namePrefix
        switch style {
        case .elevation:
            parts.append("\(Int(elevationDegrees))° up")
        case .approach:
            if let cpa = closestApproach, cpa.isApproaching,
               cpa.secondsAway <= trustedPredictionWindow {
                parts.append("in \(Int(cpa.secondsAway))s")
                parts.append("\(Int(cpa.elevationDegrees))° up")
            } else {
                parts.append("\(Int(elevationDegrees))° up")
            }
        case .proximity:
            parts.append(String(format: "%.1f km", slantRangeKm))
            parts.append("\(Int(elevationDegrees))° up")
        }
        parts.append(lookDirection)
        return parts.joined(separator: "  ")
    }
}
