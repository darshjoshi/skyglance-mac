import Foundation

/// How distances are written for the person reading them.
///
/// Only distance is a choice. Altitude stays in feet everywhere, because
/// aviation uses feet everywhere — including in countries that are otherwise
/// entirely metric — so a "3,000 m" reading would be wrong for the subject even
/// where it is right for the reader.
public enum DistanceUnit: String, Sendable, CaseIterable {
    case kilometres
    case miles

    /// What this Mac's region already uses, so most people never open the menu.
    public static var systemDefault: DistanceUnit {
        Locale.current.measurementSystem == .metric ? .kilometres : .miles
    }
}

/// The one place a distance becomes words.
///
/// Distances are turned into text in the panel, the menu bar, the alert bodies
/// and the popup card — four call sites reached from three different contexts,
/// only some of them on the main actor. Passing a unit down to each would mean
/// threading a display concern through `SkyState` and the alert builders, which
/// are otherwise pure. A single value read at format time keeps those signatures
/// clean and, more importantly, makes it impossible for two parts of the UI to
/// disagree about what "0.6" means.
///
/// Set once at launch from the stored preference, and again when the user
/// changes it. It deliberately starts metric rather than at `systemDefault`, so
/// tests do not depend on the region the machine happens to be in.
public enum Distance {
    public static var unit: DistanceUnit = .kilometres

    private static let milesPerKilometre = 0.621_371

    /// Kilometres in — the unit everything upstream already works in — words out.
    public static func format(kilometres km: Double) -> String {
        switch unit {
        case .kilometres: return String(format: "%.1f km", km)
        case .miles: return String(format: "%.1f mi", km * milesPerKilometre)
        }
    }

    /// Whole units, for readings that are never precise enough to want a decimal
    /// point — visibility is reported to the nearest kilometre at best.
    public static func formatWhole(kilometres km: Double) -> String {
        switch unit {
        case .kilometres: return "\(Int(km.rounded())) km"
        case .miles: return "\(Int((km * milesPerKilometre).rounded())) mi"
        }
    }
}
