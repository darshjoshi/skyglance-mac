import Foundation

// ── Wire format ───────────────────────────────────────────────────────────────
// adsb.lol, airplanes.live and adsb.fi all emit readsb/tar1090 JSON, so one
// decoder covers all three. Your own receiver emits the same shape.

/// `alt_baro` is a number in flight and the string "ground" on the ground.
/// Decoding it as Double fails on the ground — the classic ADS-B parsing bug.
public enum BarometricAltitude: Decodable, Sendable {
    case feet(Double)
    case onGround

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .feet(value)
        } else if let text = try? container.decode(String.self), text == "ground" {
            self = .onGround
        } else {
            self = .onGround
        }
    }

    public var feet: Double? { if case .feet(let f) = self { return f }; return nil }
    public var isOnGround: Bool { if case .onGround = self { return true }; return false }
}

public struct Aircraft: Decodable, Sendable {
    public let hex: String
    public let flight: String?
    public let registration: String?
    public let typeCode: String?
    public let description: String?
    public let operatorName: String?
    public let latitude: Double?
    public let longitude: Double?
    public let barometricAltitude: BarometricAltitude?
    public let groundSpeedKnots: Double?
    public let trackDegrees: Double?
    public let verticalRateFeetPerMinute: Double?
    public let squawk: String?
    public let emergency: String?
    public let secondsSincePosition: Double?
    public let dbFlags: Int?
    /// ADS-B emitter category: A1 light, A2 small, A3 large, A4 high-vortex large,
    /// A5 heavy, A6 high performance, A7 rotorcraft. Far more reliable for
    /// classifying an aircraft than pattern-matching type codes.
    public let category: String?

    enum CodingKeys: String, CodingKey {
        case hex, flight, latitude = "lat", longitude = "lon"
        case registration = "r", typeCode = "t", description = "desc", operatorName = "ownOp"
        case barometricAltitude = "alt_baro", groundSpeedKnots = "gs", trackDegrees = "track"
        case verticalRateFeetPerMinute = "baro_rate", squawk, emergency
        case secondsSincePosition = "seen_pos", dbFlags, category
    }

    public var callsign: String? {
        // Callsigns are space-padded to 8 characters on the wire.
        let trimmed = flight?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    public var altitudeFeet: Double? {
        guard let barometricAltitude else { return nil }
        return barometricAltitude.isOnGround ? 0 : barometricAltitude.feet
    }

    public var isOnGround: Bool { barometricAltitude?.isOnGround ?? false }
    public var isMilitary: Bool { (dbFlags ?? 0) & 1 == 1 }
    public var hasEmergency: Bool {
        guard let emergency, emergency != "none" else { return ["7500", "7600", "7700"].contains(squawk ?? "") }
        return true
    }
}

struct FeedResponse: Decodable {
    let ac: [Aircraft]?
    let aircraft: [Aircraft]?
    var all: [Aircraft] { ac ?? aircraft ?? [] }
}

// ── Sources ───────────────────────────────────────────────────────────────────

public struct FeedSource: Sendable {
    public let name: String
    public let minimumInterval: TimeInterval
    let makeURL: @Sendable (Coordinate, Int) -> URL?

    public static let all: [FeedSource] = [
        FeedSource(name: "adsb.lol", minimumInterval: 1.0) { c, r in
            URL(string: "https://api.adsb.lol/v2/point/\(c.latitude)/\(c.longitude)/\(r)")
        },
        FeedSource(name: "airplanes.live", minimumInterval: 1.0) { c, r in
            URL(string: "https://api.airplanes.live/v2/point/\(c.latitude)/\(c.longitude)/\(r)")
        },
        FeedSource(name: "adsb.fi", minimumInterval: 1.0) { c, r in
            URL(string: "https://opendata.adsb.fi/api/v2/lat/\(c.latitude)/lon/\(c.longitude)/dist/\(r)")
        },
    ]
}

public struct SourceHealth: Sendable {
    public var successes = 0
    public var failures = 0
    public var consecutiveFailures = 0
    public var openUntil: Date = .distantPast
    public var lastLatency: TimeInterval?
    public var lastError: String?
    public var isCircuitOpen: Bool { Date() < openUntil }
}

public struct Snapshot: Sendable {
    public let sightings: [Sighting]
    public let capturedAt: Date
    public let contributingSources: [String]
    public let isDegraded: Bool
    public let isStale: Bool
    public let error: String?
}

// ── Client ────────────────────────────────────────────────────────────────────

public actor FeedClient {
    private let session: URLSession
    private let userAgent: String
    private var health: [String: SourceHealth] = [:]
    private var nextSlot: [String: Date] = [:]
    private var lastGoodSnapshot: Snapshot?

    private let failuresBeforeOpen = 3
    private let breakerCooldown: TimeInterval = 30
    private let maxQueueWait: TimeInterval = 4

    public init(userAgent: String = "SkyGlance/0.1 (+https://github.com/darshjoshi/skyglance-mac)") {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
        for source in FeedSource.all { health[source.name] = SourceHealth() }
    }

    public func healthReport() -> [String: SourceHealth] { health }

    /// Query every source in parallel and union the results. Merging rather than
    /// failing over buys both redundancy and roughly 15% more aircraft.
    public func snapshot(around observer: Coordinate, radiusNauticalMiles: Int = 60) async -> Snapshot {
        let results = await withTaskGroup(of: (String, [Aircraft])?.self) { group in
            for source in FeedSource.all {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    return await self.fetch(source, observer, radiusNauticalMiles)
                }
            }
            var collected: [(String, [Aircraft])] = []
            for await result in group { if let result { collected.append(result) } }
            return collected
        }

        guard !results.isEmpty else {
            if let stale = lastGoodSnapshot {
                return Snapshot(sightings: stale.sightings, capturedAt: stale.capturedAt,
                                contributingSources: stale.contributingSources,
                                isDegraded: true, isStale: true, error: nil)
            }
            return Snapshot(sightings: [], capturedAt: Date(), contributingSources: [],
                            isDegraded: true, isStale: false, error: "all sources unavailable")
        }

        // Union by ICAO hex; freshest position wins, missing fields backfilled.
        var best: [String: (Aircraft, Set<String>)] = [:]
        for (name, aircraft) in results {
            for a in aircraft {
                guard a.coordinate != nil else { continue }
                if let entry = best[a.hex] {
                    let existing = entry.0
                    var names = entry.1
                    names.insert(name)
                    let incumbentAge = existing.secondsSincePosition ?? .greatestFiniteMagnitude
                    let challengerAge = a.secondsSincePosition ?? .greatestFiniteMagnitude
                    best[a.hex] = (challengerAge < incumbentAge ? a : existing, names)
                } else {
                    best[a.hex] = (a, [name])
                }
            }
        }

        let sightings = best.values.compactMap { aircraft, names -> Sighting? in
            guard !aircraft.isOnGround else { return nil }
            return Sighting(aircraft: aircraft, observer: observer, sources: names.sorted())
        }

        let snapshot = Snapshot(sightings: sightings, capturedAt: Date(),
                                contributingSources: results.map(\.0).sorted(),
                                isDegraded: results.count < 2, isStale: false, error: nil)
        lastGoodSnapshot = snapshot
        return snapshot
    }

    private func fetch(_ source: FeedSource, _ observer: Coordinate,
                       _ radius: Int) async -> (String, [Aircraft])? {
        guard var state = health[source.name], !state.isCircuitOpen else { return nil }

        // Rate limits are per-source and global. Reserve the next slot and wait
        // for it rather than skipping, or a second viewport gets starved.
        let now = Date()
        let slot = max(nextSlot[source.name] ?? now, now)
        let wait = slot.timeIntervalSince(now)
        guard wait <= maxQueueWait else { return nil }
        nextSlot[source.name] = slot.addingTimeInterval(source.minimumInterval)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        guard let url = source.makeURL(observer, radius) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw FeedError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            // Under burst these services can return an HTML error page with a 200,
            // so a decode failure here is a normal, expected outcome.
            let decoded = try JSONDecoder().decode(FeedResponse.self, from: data)
            state.successes += 1
            state.consecutiveFailures = 0
            state.lastLatency = Date().timeIntervalSince(started)
            state.lastError = nil
            health[source.name] = state
            return (source.name, decoded.all)
        } catch {
            state.failures += 1
            state.consecutiveFailures += 1
            state.lastError = error.localizedDescription
            state.lastLatency = Date().timeIntervalSince(started)
            if state.consecutiveFailures >= failuresBeforeOpen {
                state.openUntil = Date().addingTimeInterval(breakerCooldown)
            }
            health[source.name] = state
            return nil
        }
    }
}

enum FeedError: LocalizedError {
    case badStatus(Int)
    var errorDescription: String? {
        switch self { case .badStatus(let code): return "HTTP \(code)" }
    }
}
