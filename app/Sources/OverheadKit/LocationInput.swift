import Foundation

/// Parsing for the one thing every user has to type. Lives here rather than in a
/// view because two screens now take it — first-run setup and settings — and
/// because "did the user type a valid place" is worth testing without a UI.
public enum LocationInput {

    public enum Problem: Equatable, Error {
        case empty
        case notTwoNumbers
        case latitudeOutOfRange
        case longitudeOutOfRange

        public var message: String {
            switch self {
            case .empty:
                return "Enter a latitude and longitude."
            case .notTwoNumbers:
                return "Expected two numbers separated by a comma, like 51.4700, -0.4543"
            case .latitudeOutOfRange:
                return "Latitude must be between -90 and 90."
            case .longitudeOutOfRange:
                return "Longitude must be between -180 and 180."
            }
        }
    }

    /// Accepts "51.47, -0.4543" and the shapes people actually paste: extra
    /// whitespace, a space instead of a comma, and the degree signs that come
    /// with a copy out of Apple Maps or Wikipedia.
    public static func parse(_ text: String) -> Result<Coordinate, Problem> {
        let cleaned = text
            .replacingOccurrences(of: "°", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .failure(.empty) }

        let parts = cleaned
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard parts.count == 2,
              let latitude = Double(parts[0]), let longitude = Double(parts[1]) else {
            return .failure(.notTwoNumbers)
        }
        guard abs(latitude) <= 90 else { return .failure(Problem.latitudeOutOfRange) }
        guard abs(longitude) <= 180 else { return .failure(Problem.longitudeOutOfRange) }
        return .success(Coordinate(latitude: latitude, longitude: longitude))
    }

    /// How a coordinate is shown back to the user, and what goes in the field
    /// when settings opens on an existing location.
    public static func format(_ c: Coordinate) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    /// Placeholder text. Heathrow: busy, public, and obviously not the user's house.
    public static let example = "51.47000, -0.45430"
}
