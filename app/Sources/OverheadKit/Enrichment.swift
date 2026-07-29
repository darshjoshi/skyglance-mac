import Foundation

// Ported from the verified Node implementation in server.mjs. Measured against
// 14 live aircraft over a major metropolitan area: route 12/14, aircraft 11/14, photo 12/14 —
// so roughly one in seven has no route and every field must tolerate nil.

public struct AirportRef: Codable, Sendable, Equatable {
    public let icao: String?
    public let iata: String?
    public let name: String?
    public let municipality: String?

    public init(icao: String?, iata: String?, name: String? = nil, municipality: String? = nil) {
        self.icao = icao
        self.iata = iata
        self.name = name
        self.municipality = municipality
    }

    /// "Newark" beats "Newark Liberty International Airport" in a 356pt panel.
    public var shortName: String {
        municipality ?? name ?? iata ?? icao ?? "?"
    }
    public var code: String { iata ?? icao ?? "?" }
}

public struct RouteInfo: Codable, Sendable, Equatable {
    public let airline: String?
    public let origin: AirportRef?
    public let destination: AirportRef?

    public init(airline: String?, origin: AirportRef?, destination: AirportRef?) {
        self.airline = airline
        self.origin = origin
        self.destination = destination
    }

    /// Only meaningful when both ends are known; a half-route reads as broken.
    public var isComplete: Bool { origin != nil && destination != nil }
}

public struct AircraftInfo: Codable, Sendable, Equatable {
    public let registration: String?
    public let type: String?
    public let manufacturer: String?
    public let owner: String?
    public let country: String?

    public init(registration: String?, type: String?, manufacturer: String?,
                owner: String?, country: String?) {
        self.registration = registration
        self.type = type
        self.manufacturer = manufacturer
        self.owner = owner
        self.country = country
    }
}

public struct PhotoInfo: Codable, Sendable, Equatable {
    public let thumbnailURL: String
    public let link: String
    /// Attribution is a condition of use, so the credit travels with the URL.
    public let photographer: String

    public init(thumbnailURL: String, link: String, photographer: String) {
        self.thumbnailURL = thumbnailURL
        self.link = link
        self.photographer = photographer
    }
}

public struct AircraftDetail: Sendable, Equatable {
    public let hex: String
    public var info: AircraftInfo?
    public var route: RouteInfo?
    public var photo: PhotoInfo?

    public init(hex: String, info: AircraftInfo? = nil,
                route: RouteInfo? = nil, photo: PhotoInfo? = nil) {
        self.hex = hex
        self.info = info
        self.route = route
        self.photo = photo
    }

    public var isEmpty: Bool { info == nil && route == nil && photo == nil }
}

// ── Wire formats ──────────────────────────────────────────────────────────────

struct ADSBDBAircraftResponse: Decodable {
    struct Wrapper: Decodable { let aircraft: Aircraft? }
    struct Aircraft: Decodable {
        let type: String?
        let icao_type: String?
        let manufacturer: String?
        let registration: String?
        let registered_owner: String?
        let registered_owner_country_name: String?
    }
    let response: Wrapper
}

struct ADSBDBRouteResponse: Decodable {
    struct Wrapper: Decodable { let flightroute: Route? }
    struct Route: Decodable {
        struct Airline: Decodable { let name: String? }
        struct Airport: Decodable {
            let icao_code: String?
            let iata_code: String?
            let name: String?
            let municipality: String?
        }
        let airline: Airline?
        let origin: Airport?
        let destination: Airport?
    }
    let response: Wrapper
}

struct HexDBAircraft: Decodable {
    let registration: String?
    let manufacturer: String?
    let typeName: String?
    let owners: String?

    // hexdb capitalises its keys, and a member literally named `Type` is illegal.
    enum CodingKeys: String, CodingKey {
        case registration = "Registration"
        case manufacturer = "Manufacturer"
        case typeName = "Type"
        case owners = "RegisteredOwners"
    }
}

struct HexDBRoute: Decodable {
    let route: String?
}

struct PlanespottersResponse: Decodable {
    struct Photo: Decodable {
        struct Image: Decodable { let src: String? }
        let thumbnail: Image?
        let thumbnail_large: Image?
        let link: String?
        let photographer: String?
    }
    let photos: [Photo]?
}

// ── Client ────────────────────────────────────────────────────────────────────

/// On-demand only. These are volunteer-run services: enrich when the user
/// selects something or an alert fires, never for a whole list on every poll.
public actor EnrichmentClient {
    private let session: URLSession
    private let userAgent: String

    // Aircraft type and route are effectively immutable, so cache forever —
    // including misses, or an unknown callsign is re-requested on every tap.
    private var aircraftCache: [String: AircraftInfo?] = [:]
    private var routeCache: [String: RouteInfo?] = [:]
    private var photoCache: [String: PhotoInfo?] = [:]

    private let cacheURL: URL?

    public init(userAgent: String = "SkyGlance/0.1 (+https://github.com/darshjoshi/skyglance-mac)",
                cacheDirectory: URL? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent

        let directory = cacheDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SkyGlance", isDirectory: true)
        self.cacheURL = directory?.appendingPathComponent("enrichment.json")
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Decoded here rather than via a method call: an actor's init is
        // nonisolated and cannot invoke isolated members.
        if let cacheURL = self.cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) {
            aircraftCache = decoded.aircraft
            routeCache = decoded.routes
            photoCache = decoded.photos
        }
    }

    // MARK: - Public

    public func detail(hex: String, callsign: String?, registration: String?) async -> AircraftDetail {
        let info = await aircraft(hex: hex)
        // adsbdb often knows the registration even when the feed does not.
        let reg = registration ?? info?.registration
        async let routeTask = route(callsign: callsign)
        async let photoTask = photo(registration: reg)
        let detail = AircraftDetail(hex: hex, info: info, route: await routeTask, photo: await photoTask)
        saveCache()
        return detail
    }

    /// Route alone, for wording a notification without paying for a photo.
    public func route(callsign: String?) async -> RouteInfo? {
        guard let callsign, !callsign.isEmpty else { return nil }
        if let cached = routeCache[callsign] { return cached }

        let providers: [() async throws -> RouteInfo?] = [
            { [self] in
                let d: ADSBDBRouteResponse = try await get(
                    "https://api.adsbdb.com/v0/callsign/\(callsign)")
                guard let r = d.response.flightroute else { return nil }
                return RouteInfo(
                    airline: r.airline?.name,
                    origin: r.origin.map { AirportRef(icao: $0.icao_code, iata: $0.iata_code,
                                                      name: $0.name, municipality: $0.municipality) },
                    destination: r.destination.map { AirportRef(icao: $0.icao_code, iata: $0.iata_code,
                                                                name: $0.name, municipality: $0.municipality) })
            },
            { [self] in
                let d: HexDBRoute = try await get("https://hexdb.io/api/v1/route/icao/\(callsign)")
                guard let route = d.route, route.contains("-") else { return nil }
                let parts = route.split(separator: "-")
                guard parts.count == 2 else { return nil }
                return RouteInfo(airline: nil,
                                 origin: AirportRef(icao: String(parts[0]), iata: nil),
                                 destination: AirportRef(icao: String(parts[1]), iata: nil))
            },
        ]
        let result = await firstOf(providers)
        routeCache[callsign] = result
        return result
    }

    public func aircraft(hex: String) async -> AircraftInfo? {
        if let cached = aircraftCache[hex] { return cached }
        let providers: [() async throws -> AircraftInfo?] = [
            { [self] in
                let d: ADSBDBAircraftResponse = try await get(
                    "https://api.adsbdb.com/v0/aircraft/\(hex)")
                guard let a = d.response.aircraft else { return nil }
                return AircraftInfo(registration: a.registration, type: a.type,
                                    manufacturer: a.manufacturer, owner: a.registered_owner,
                                    country: a.registered_owner_country_name)
            },
            { [self] in
                let d: HexDBAircraft = try await get("https://hexdb.io/api/v1/aircraft/\(hex)")
                guard let registration = d.registration else { return nil }
                return AircraftInfo(registration: registration, type: d.typeName,
                                    manufacturer: d.manufacturer, owner: d.owners,
                                    country: nil)
            },
        ]
        let result = await firstOf(providers)
        aircraftCache[hex] = result
        return result
    }

    public func photo(registration: String?) async -> PhotoInfo? {
        guard let registration, !registration.isEmpty else { return nil }
        if let cached = photoCache[registration] { return cached }
        let providers: [() async throws -> PhotoInfo?] = [
            { [self] in
                let d: PlanespottersResponse = try await get(
                    "https://api.planespotters.net/pub/photos/reg/\(registration)")
                guard let p = d.photos?.first,
                      let src = p.thumbnail_large?.src ?? p.thumbnail?.src,
                      let link = p.link else { return nil }
                return PhotoInfo(thumbnailURL: src, link: link,
                                 photographer: p.photographer ?? "unknown")
            },
        ]
        let result = await firstOf(providers)
        photoCache[registration] = result
        return result
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else { throw EnrichmentError.badURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // planespotters rejects generic user agents outright.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EnrichmentError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// First provider that yields a value wins; failures fall through silently.
    /// `try?` already flattens the optional a provider returns, so one unwrap
    /// covers both "threw" and "returned nil".
    private func firstOf<T>(_ providers: [() async throws -> T?]) async -> T? {
        for provider in providers {
            if let value = try? await provider() { return value }
        }
        return nil
    }

    // MARK: - Persistence

    private struct CacheFile: Codable {
        var aircraft: [String: AircraftInfo?]
        var routes: [String: RouteInfo?]
        var photos: [String: PhotoInfo?]
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let file = CacheFile(aircraft: aircraftCache, routes: routeCache, photos: photoCache)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    public func cacheCounts() -> (aircraft: Int, routes: Int, photos: Int) {
        (aircraftCache.count, routeCache.count, photoCache.count)
    }
}

enum EnrichmentError: Error {
    case badURL
    case badStatus(Int)
}
