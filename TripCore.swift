import Foundation

struct Airport: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var city: String
    var country: String
    var large: Bool
    var id: String { code }
    var label: String { "\(city) (\(code))" }
}

struct TripQuery: Codable, Equatable {
    var origin: String
    var destination: String
    var departure: String
    var returnDate: String?
    var adults = 2
    var children = 0
    var cabin = "economy"
    var maxStops: Int?
    var airlines: [String] = []
    var travelerCount: Int { adults + children }
    var isRoundTrip: Bool { returnDate != nil }
    var tripLabel: String { isRoundTrip ? "Round trip" : "One way" }
}

struct FlightSegment: Codable, Hashable {
    var origin: String
    var originName: String
    var destination: String
    var destinationName: String
    var date: String
    var departure: String
    var arrival: String
    var carrier: String
    var number: String
    var durationMinutes: Int
    var aircraft: String
    var flightNumber: String { "\(carrier) \(number)" }
}

struct FlightOption: Codable, Identifiable, Equatable {
    var id: String
    var totalCents: Int
    var airlines: [String]
    var segments: [FlightSegment]
    var durationMinutes: Int
    var stops: Int
    var departureTime: String { String(segments.first?.departure.suffix(5) ?? "—") }
    var arrivalTime: String {
        let time = String(segments.last?.arrival.suffix(5) ?? "—")
        guard let first = segments.first, let last = segments.last else { return time }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let departure = formatter.date(from: first.date), let arrival = formatter.date(from: String(last.arrival.prefix(10))) else { return time }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: departure, to: arrival).day ?? 0
        return days > 0 ? time + " (+\(days)d)" : time
    }
    var route: String { ([segments.first?.origin ?? ""] + segments.map(\.destination)).joined(separator: " → ") }
    var flightNumbers: String { segments.map(\.flightNumber).joined(separator: " · ") }
    var stopsLabel: String { stops == 0 ? "Nonstop" : "\(stops) \(stops == 1 ? "stop" : "stops")" }
    var durationLabel: String { "\(durationMinutes / 60)h \(durationMinutes % 60)m" }
}

struct FlightSearch: Decodable {
    var query: TripQuery
    var stage: String
    var options: [FlightOption]
    var outbound: FlightOption?
    var checkedAt: String
    var searchURL: String
}

struct RefreshedQuote: Decodable {
    var available: Bool
    var totalCents: Int?
    var outbound: FlightOption?
    var returning: FlightOption?
    var bookingURL: String?
    var checkedAt: String
    var detail: String?
}

struct PriceObservation: Codable, Identifiable {
    var id = UUID()
    var at = Date()
    var fareCents: Int
}

struct PriceAlert: Codable, Identifiable {
    var id = UUID()
    var at = Date()
    var totalCents: Int
    var reason: String
}

enum TrackingMode: String, Codable { case cheapest, selected }

struct TrackedTrip: Codable, Identifiable {
    var id = UUID()
    var name: String
    var query: TripQuery
    var mode: TrackingMode
    var pinnedOutbound: FlightOption?
    var pinnedReturn: FlightOption?
    var displayOutbound: FlightOption?
    var displayReturn: FlightOption?
    var targetCents: Int?
    var baggageCents: Int
    var history: [PriceObservation] = []
    var alerts: [PriceAlert] = []
    var isPaused = false
    var archived = false
    var lastAttempt: Date?
    var lastError: String?
    var bookingURL: String?
    var currentFare: Int? { history.last?.fareCents }
    var currentTotal: Int? { currentFare.map { $0 + baggageCents } }
    var lowestTotal: Int? { history.map(\.fareCents).min().map { $0 + baggageCents } }
    var lastSuccess: Date? { history.last?.at }
    var isPastDeparture: Bool { query.departure < flightDay(Date()) }
    var trackingLabel: String { mode == .cheapest ? "Cheapest matching trip" : "Selected flights" }
}

struct TrackerPreferences: Codable {
    var macAlerts = true
    var reminderAlerts = false
    var reminderCalendarIdentifier: String?
    var intervalMinutes = 60
    var preventIdleSleep = false

    enum CodingKeys: String, CodingKey {
        case macAlerts, reminderAlerts, reminderCalendarIdentifier, intervalMinutes, preventIdleSleep
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        macAlerts = try values.decodeIfPresent(Bool.self, forKey: .macAlerts) ?? true
        // Existing ntfy settings never opt a user into creating iCloud reminders.
        reminderAlerts = try values.decodeIfPresent(Bool.self, forKey: .reminderAlerts) ?? false
        reminderCalendarIdentifier = try values.decodeIfPresent(String.self, forKey: .reminderCalendarIdentifier)
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        preventIdleSleep = try values.decodeIfPresent(Bool.self, forKey: .preventIdleSleep) ?? false
    }
}

struct TrackerData: Codable {
    var version = 1
    var trips: [TrackedTrip] = []
    var preferences = TrackerPreferences()
}

enum TrackerPage: Hashable { case search, trip(UUID), health, settings, archive }

func flightDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

func readableDay(_ value: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .omitted)
}

func money(_ cents: Int) -> String {
    (Double(cents) / 100).formatted(.currency(code: "USD"))
}

func parseMoney(_ text: String) -> Int? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
    guard cleaned.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil, var decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
          decimal >= 0, decimal <= 100_000_000 else { return nil }
    decimal *= 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &decimal, 0, .plain)
    return NSDecimalNumber(decimal: rounded).intValue
}

func priceAlertReason(newFare: Int, previousFares: [Int], baggage: Int, target: Int?) -> String? {
    guard newFare > 0 else { return nil }
    let newLow = previousFares.min().map { newFare < $0 } ?? false
    let total = newFare + baggage
    let below = target.map { total < $0 } ?? false
    let crossedOrFell = previousFares.last.map { old in
        (target.map { old + baggage >= $0 } ?? false) || newFare < old
    } ?? true
    if newLow && below { return "New low · below your target" }
    if newLow { return "New lowest price" }
    if below && crossedOrFell { return "Below your target" }
    return nil
}

func trackerTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
