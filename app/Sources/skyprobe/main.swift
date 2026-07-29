// Threshold tuning tool. Samples a real sky and reports how many aircraft would
// clear the alert bar, so the policy can be set from evidence rather than
// guesswork.
//
//   swift run skyprobe <lat> <lon> [minutes] [facing] [halfWidth]
//
// Omit facing and halfWidth to score the whole sky; supply them to model a
// one-sided view, e.g. `skyprobe 51.47 -0.4543 5 90 110` for east ±110°.
import Foundation
import OverheadKit

let args = CommandLine.arguments
guard args.count >= 3, let lat = Double(args[1]), let lon = Double(args[2]) else {
    print("usage: skyprobe <lat> <lon> [minutes] [facing] [halfWidth]")
    exit(1)
}
let minutes = args.count >= 4 ? (Double(args[3]) ?? 5) : 5
let observer = Coordinate(latitude: lat, longitude: lon)
let profile: ViewingProfile = {
    guard args.count >= 6, let facing = Double(args[4]),
          let halfWidth = Double(args[5]) else { return .allSky }
    return ViewingProfile(bearingCenter: facing, bearingHalfWidth: halfWidth,
                          minimumElevation: 0)
}()
let scorer = InterestScorer()
let policy = AlertPolicy()

let client = FeedClient()
let weather = WeatherClient()
if let conditions = await weather.conditions(at: observer) {
    print("Conditions: \(conditions.summary)\n")
}

var qualifying: [String: (Interest, Sighting)] = [:]   // best score seen per aircraft
var seenTotal = Set<String>()
var seenVisible = Set<String>()
var rounds = 0
let deadline = Date().addingTimeInterval(minutes * 60)

print("Sampling for \(Int(minutes)) minutes…")
while Date() < deadline {
    rounds += 1
    let snapshot = await client.snapshot(around: observer, radiusNauticalMiles: 40)
    for s in snapshot.sightings {
        seenTotal.insert(s.id)
        guard profile.canSee(s) else { continue }
        seenVisible.insert(s.id)
        guard let interest = scorer.score(s) else { continue }
        if let existing = qualifying[s.id], existing.0.score >= interest.score { continue }
        qualifying[s.id] = (interest, s)
    }
    try? await Task.sleep(nanoseconds: 5_000_000_000)
}

let clearing = qualifying.filter { $0.value.0.score >= policy.minimumScore }
let hours = minutes / 60
let ratePerHour = Double(clearing.count) / hours
let perWakingDay = ratePerHour * 16

print("""

\(rounds) samples over \(Int(minutes)) min
  distinct aircraft seen        \(seenTotal.count)
  inside the visible arc       \(seenVisible.count)  (\(seenTotal.isEmpty ? 0 : seenVisible.count * 100 / seenTotal.count)% \
of all traffic — the rest is behind you)
  scored at all                 \(qualifying.count)
  cleared threshold (\(Int(policy.minimumScore)))       \(clearing.count)

  => roughly \(String(format: "%.1f", ratePerHour))/hour, \(String(format: "%.0f", perWakingDay)) per waking day
     policy caps delivery at \(policy.maximumPerDay)/day with a \(Int(policy.minimumGap / 60))-min gap
""")

if !clearing.isEmpty {
    print("\nWhat would have alerted:")
    for (_, (interest, s)) in clearing.sorted(by: { $0.value.0.score > $1.value.0.score }).prefix(12) {
        print(String(format: "  %5.1f  %-10@ %-5@ %6.0f ft  %4.1f km  %2.0f° %-3@  %@",
                     interest.score, s.label as NSString, (s.typeCode ?? "?") as NSString,
                     s.altitudeFeet, s.slantRangeKm, s.elevationDegrees,
                     s.lookDirection as NSString, interest.reason as NSString))
    }
}

let byCategory = Dictionary(grouping: clearing.values, by: { $0.0.category })
if !byCategory.isEmpty {
    print("\nBy category: " + byCategory
        .map { "\($0.key.rawValue)×\($0.value.count)" }
        .sorted().joined(separator: ", "))
}
