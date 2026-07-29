import Foundation

/// Whether the sky is worth looking at. Open-Meteo is free and needs no API key.
public struct SkyConditions: Sendable {
    public let cloudCoverPercent: Int
    public let visibilityMetres: Double
    public let isDaylight: Bool
    public let fetchedAt: Date

    public var summary: String {
        let seeing: String
        if !isDaylight { seeing = "dark" }
        else if cloudCoverPercent > 80 { seeing = "overcast" }
        else if cloudCoverPercent > 40 { seeing = "broken cloud" }
        else { seeing = "clear" }
        return "\(cloudCoverPercent)% cloud · \(Int(visibilityMetres / 1000)) km · \(seeing)"
    }
}

public actor WeatherClient {
    private var cached: SkyConditions?
    /// Cloud cover does not change in seconds, and the poll loop runs every 3.
    private let maximumAge: TimeInterval = 10 * 60
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: config)
    }

    public func conditions(at coordinate: Coordinate) async -> SkyConditions? {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < maximumAge { return cached }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(coordinate.latitude)),
            .init(name: "longitude", value: String(coordinate.longitude)),
            .init(name: "current", value: "cloud_cover,visibility,is_day"),
        ]
        guard let url = components.url else { return cached }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let conditions = SkyConditions(
                cloudCoverPercent: decoded.current.cloud_cover,
                visibilityMetres: decoded.current.visibility,
                isDaylight: decoded.current.is_day == 1,
                fetchedAt: Date())
            cached = conditions
            return conditions
        } catch {
            // Never let a weather failure suppress aircraft alerts — returning the
            // stale value (or nil) leaves the gate open rather than closed.
            return cached
        }
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let cloud_cover: Int
        let visibility: Double
        let is_day: Int
    }
    let current: Current
}

public extension SkyConditions {
    /// Whether an aircraft at this altitude could actually be seen from the
    /// ground right now. Alerts use this to choose between "look up" and
    /// "you just missed one" — the app should never point at an invisible sky.
    func permitsViewing(altitudeFeet: Double, policy: AlertPolicy) -> Bool {
        if policy.requireDaylight && !isDaylight { return false }
        guard cloudCoverPercent > policy.maximumCloudCover else { return true }
        // Below the deck you are under the cloud, not behind it.
        return altitudeFeet > 0 && altitudeFeet <= policy.underCloudCeilingFeet
    }

    /// Why it can't be seen, for wording an alert honestly.
    func obstruction(altitudeFeet: Double, policy: AlertPolicy) -> String? {
        if permitsViewing(altitudeFeet: altitudeFeet, policy: policy) { return nil }
        if policy.requireDaylight && !isDaylight { return "too dark to see" }
        return "too cloudy to see"
    }
}
