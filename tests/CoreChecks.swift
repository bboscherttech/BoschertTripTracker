import Foundation

@main
struct CoreChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        check(priceAlertReason(newFare: 60000, previousFares: [], baggage: 0, target: nil) == nil, "Initial fare is a baseline")
        check(priceAlertReason(newFare: 60000, previousFares: [60000], baggage: 0, target: 70000) == nil, "Unchanged price does not repeat alerts")
        check(priceAlertReason(newFare: 59900, previousFares: [60000], baggage: 0, target: nil) == "New lowest price", "$1 decrease counts")
        check(priceAlertReason(newFare: 40000, previousFares: [30000, 60000], baggage: 0, target: 50000) == "Below your target", "Crossing target counts without a record low")
        check(priceAlertReason(newFare: 35000, previousFares: [30000, 40000], baggage: 0, target: 50000) == "Below your target", "Further decreases below target count")
        check(priceAlertReason(newFare: 50000, previousFares: [], baggage: 0, target: 50000) == nil, "Target comparison is strictly below")
        check(priceAlertReason(newFare: 40000, previousFares: [50000], baggage: 10000, target: 51000) == "New low · below your target", "Bags are included once in the trip total")
        check(priceAlertReason(newFare: 0, previousFares: [50000], baggage: 0, target: 50000) == nil, "Missing quote cannot become a free trip")
        check(parseMoney("$1,250.50") == 125050, "Dollar amounts preserve cents")
        check(parseMoney("12abc") == nil, "Malformed amounts are rejected")
        check(parseMoney("-1") == nil, "Negative budgets are rejected")
        check(parseMoney("") == nil, "Blank target can be treated as optional")
        let query = TripQuery(origin: "ORD", destination: "BOS", departure: "2030-12-01", returnDate: "2030-12-08")
        var trip = TrackedTrip(name: "Boston trip", query: query, mode: .cheapest, targetCents: 70000, baggageCents: 5000)
        trip.history = [PriceObservation(fareCents: 62600), PriceObservation(fareCents: 60000)]
        check(trip.currentTotal == 65000, "Current price includes the trip bag estimate")
        check(trip.lowestTotal == 65000, "Record low covers the complete party")
        let data = TrackerData(trips: [trip])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TrackerData.self, from: encoder.encode(data))
        check(restored.trips[0].id == trip.id, "Trip identity persists across restart")
        check(restored.trips[0].history.map(\.fareCents) == [62600, 60000], "Price history persists across restart")
        check(restored.trips[0].targetCents == 70000 && restored.trips[0].baggageCents == 5000, "Target and bag adjustment persist")
        let legacyPreferences = Data(#"{"macAlerts":false,"phoneAlerts":true,"phoneChannel":"old-private-channel","intervalMinutes":30,"preventIdleSleep":true}"#.utf8)
        let migrated = try decoder.decode(TrackerPreferences.self, from: legacyPreferences)
        check(!migrated.macAlerts && migrated.intervalMinutes == 30 && migrated.preventIdleSleep,
              "The update preserves existing notification, polling and power choices")
        check(!migrated.reminderAlerts && migrated.reminderCalendarIdentifier == nil,
              "Legacy phone settings do not opt users into iCloud reminders")
        var updated = data
        updated.preferences.reminderAlerts = true
        updated.preferences.reminderCalendarIdentifier = "test-icloud-list"
        let reminderRestored = try decoder.decode(TrackerData.self, from: encoder.encode(updated))
        check(reminderRestored.preferences.reminderAlerts && reminderRestored.preferences.reminderCalendarIdentifier == "test-icloud-list",
              "The chosen Reminders list and enabled state persist")
        check(reminderRestored.trips[0].history.map(\.fareCents) == [62600, 60000],
              "Enabling Reminders does not change saved trip history")
        print("\(checks) trip-pricing, alert, and persistence checks passed.")
    }
}
