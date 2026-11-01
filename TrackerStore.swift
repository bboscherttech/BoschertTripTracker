import AppKit
import Combine
import EventKit
import Foundation
import UserNotifications

struct FlightResponse: Decodable {
    var health: HealthState
    var search: FlightSearch?
    var refresh: RefreshedQuote?
    var bookingURL: String?
    var error: String?
}

@MainActor
final class TrackerStore: ObservableObject {
    @Published var data = TrackerData()
    @Published var page: TrackerPage? = .search
    @Published var searchResult: FlightSearch?
    @Published var busy = false
    @Published var error: String?
    @Published var notificationError: String?
    @Published var notificationStatus: String?
    @Published var connectingReminders = false
    @Published var checkingTrip: UUID?
    @Published var airports: [Airport] = []
    @Published var storageAvailable = true
    let health: StatusModel
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var awakeToken: NSObjectProtocol?
    private let reminderService = ReminderAlertService()
    private let directory: URL
    private var tripFile: URL { directory.appendingPathComponent("trips.json") }
    private var healthFile: URL { directory.appendingPathComponent("health.json") }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let override = Bundle.main.object(forInfoDictionaryKey: "BoschertTripTrackerDataDirectory") as? String {
            directory = URL(fileURLWithPath: override)
        } else if let index = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1])
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Boschert Trip Tracker")
        }
        health = StatusModel(stateURL: directory.appendingPathComponent("health.json"))
        if let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
           let bytes = try? Data(contentsOf: url), let loaded = try? JSONDecoder().decode([Airport].self, from: bytes) {
            airports = loaded
        }
        if FileManager.default.fileExists(atPath: tripFile.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let loaded = try decoder.decode(TrackerData.self, from: Data(contentsOf: tripFile))
                guard loaded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                data = loaded
            } catch {
                storageAvailable = false
                self.error = "Saved trips could not be read. The original file has been preserved."
            }
        }
        updateAwakeActivity()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkDueTrips() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkDueTrips() }
        }
        Task { await checkDueTrips() }
    }

    var activeTrips: [TrackedTrip] { data.trips.filter { !$0.archived } }
    func trip(_ id: UUID) -> TrackedTrip? { data.trips.first { $0.id == id } }
    func airportLabel(_ code: String) -> String { airports.first { $0.code == code }?.label ?? code }
    func save() {
        guard storageAvailable else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: tripFile, options: .atomic)
        } catch {
            self.error = "The latest changes could not be saved. Check this Mac's available storage."
        }
    }

    func request(_ value: [String: Any]) async throws -> FlightResponse {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let executable = resources.appendingPathComponent("worker/triptracker-worker")
        let args = ["--state", healthFile.path, "--request"]
        let input = try JSONSerialization.data(withJSONObject: value)
        let bytes = try await Task.detached {
            try runWorker(executable: executable, arguments: args, inputData: input)
        }.value
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(FlightResponse.self, from: bytes)
        health.health = response.health
        return response
    }

    func queryObject(_ query: TripQuery) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(query))
    }
    func optionObject(_ option: FlightOption) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(option))
    }

    func search(_ query: TripQuery, outbound: FlightOption? = nil) async {
        guard !busy else { return }
        busy = true
        error = nil
        searchResult = nil
        defer { busy = false }
        do {
            var input: [String: Any] = ["action": "search", "query": try queryObject(query)]
            if let outbound { input["outbound"] = try optionObject(outbound) }
            let response = try await request(input)
            if let message = response.error { error = message; return }
            searchResult = response.search
        } catch {
            self.error = "Flight search could not finish. Please try again."
        }
    }

    func selectedBookingURL(query: TripQuery, outbound: FlightOption, returning: FlightOption?) async -> String? {
        do {
            var input: [String: Any] = ["action": "booking", "query": try queryObject(query), "outbound": try optionObject(outbound)]
            if let returning { input["returning"] = try optionObject(returning) }
            return try await request(input).bookingURL
        } catch { return nil }
    }

    func addTrip(name: String, mode: TrackingMode, query: TripQuery, outbound: FlightOption,
                 returning: FlightOption?, fare: Int, target: Int?, baggage: Int, sourceURL: String, observedAt: Date) async {
        guard storageAvailable else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var trip = TrackedTrip(name: trimmed.isEmpty ? "\(query.origin) → \(query.destination)" : trimmed,
            query: query, mode: mode, pinnedOutbound: mode == .selected ? outbound : nil,
            pinnedReturn: mode == .selected ? returning : nil, displayOutbound: outbound, displayReturn: returning,
            targetCents: target, baggageCents: baggage, lastAttempt: observedAt, bookingURL: sourceURL)
        let reason = priceAlertReason(newFare: fare, previousFares: [], baggage: baggage, target: target)
        trip.history = [PriceObservation(at: observedAt, fareCents: fare)]
        if let reason { trip.alerts.append(PriceAlert(totalCents: fare + baggage, reason: reason)) }
        data.trips.append(trip)
        save()
        updateAwakeActivity()
        page = .trip(trip.id)
        if data.preferences.macAlerts { await requestNotificationPermission() }
        if let reason { await deliverAlert(trip: trip, total: fare + baggage, reason: reason) }
    }

    func updateTrip(_ id: UUID, name: String, target: Int?, baggage: Int) {
        guard let index = data.trips.firstIndex(where: { $0.id == id }) else { return }
        data.trips[index].name = name
        data.trips[index].targetCents = target
        data.trips[index].baggageCents = baggage
        save()
    }

    func togglePause(_ id: UUID) {
        guard let index = data.trips.firstIndex(where: { $0.id == id }) else { return }
        data.trips[index].isPaused.toggle()
        save()
        updateAwakeActivity()
    }
    func archive(_ id: UUID, archived: Bool = true) {
        guard let index = data.trips.firstIndex(where: { $0.id == id }) else { return }
        data.trips[index].archived = archived
        save()
        page = archived ? .search : .trip(id)
        updateAwakeActivity()
    }

    func checkDueTrips(force: Bool = false) async {
        updateAwakeActivity()
        guard !busy, storageAvailable else { return }
        for trip in activeTrips where !trip.isPaused && !trip.isPastDeparture {
            let due = force || (trip.lastAttempt.map { Date().timeIntervalSince($0) >= Double(data.preferences.intervalMinutes * 60) } ?? true)
            if due { await refreshTrip(trip.id) }
        }
    }

    func refreshTrip(_ id: UUID) async {
        guard !busy, let trip = trip(id), !trip.isPastDeparture else { return }
        busy = true
        checkingTrip = id
        defer { busy = false; checkingTrip = nil }
        if let index = data.trips.firstIndex(where: { $0.id == id }) {
            data.trips[index].lastAttempt = Date()
            save()
        }
        do {
            var input: [String: Any] = ["action": "refresh", "query": try queryObject(trip.query)]
            if let option = trip.pinnedOutbound { input["outbound"] = try optionObject(option) }
            if let option = trip.pinnedReturn { input["returning"] = try optionObject(option) }
            let response = try await request(input)
            guard let index = data.trips.firstIndex(where: { $0.id == id }) else { return }
            if let message = response.error {
                data.trips[index].lastError = message
                save()
                return
            }
            guard let quote = response.refresh, quote.available, let fare = quote.totalCents, fare > 0 else {
                data.trips[index].lastError = response.refresh?.detail ?? "No matching fare was available."
                save()
                return
            }
            let current = data.trips[index]
            let reason = priceAlertReason(newFare: fare, previousFares: current.history.map(\.fareCents),
                                          baggage: current.baggageCents, target: current.targetCents)
            data.trips[index].history.append(PriceObservation(fareCents: fare))
            data.trips[index].displayOutbound = quote.outbound
            data.trips[index].displayReturn = quote.returning
            data.trips[index].bookingURL = quote.bookingURL
            data.trips[index].lastError = nil
            if let reason {
                data.trips[index].alerts.append(PriceAlert(totalCents: fare + current.baggageCents, reason: reason))
            }
            save()
            if let reason { await deliverAlert(trip: data.trips[index], total: fare + current.baggageCents, reason: reason) }
        } catch {
            if let index = data.trips.firstIndex(where: { $0.id == id }) {
                data.trips[index].lastError = "The price check could not finish. The last successful price is preserved."
                save()
            }
        }
    }

    func preferencesChanged() {
        save()
        updateAwakeActivity()
    }
    func updateAwakeActivity() {
        let needsAwake = data.preferences.preventIdleSleep && activeTrips.contains { !$0.isPaused && !$0.isPastDeparture }
        if needsAwake && awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
                                                              reason: "Checking tracked trip prices")
        } else if !needsAwake, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }

    func requestNotificationPermission() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { notificationError = "Mac notification permission could not be requested." }
    }

    var remindersConnected: Bool {
        reminderService.isConnected(identifier: data.preferences.reminderCalendarIdentifier)
    }

    var remindersConnectionDescription: String {
        if remindersConnected { return "Connected to the Boschert Trip Tracker list in iCloud Reminders." }
        if data.preferences.reminderCalendarIdentifier != nil {
            return "Reminders needs reconnecting. Check its permission and that iCloud Reminders is enabled on this Mac."
        }
        return "Not connected. Set up Reminders alerts below when you are ready to test."
    }

    func connectReminders() async {
        guard !connectingReminders, storageAvailable else { return }
        connectingReminders = true
        notificationError = nil
        notificationStatus = nil
        defer { connectingReminders = false }
        do {
            let identifier = try await reminderService.connect(identifier: data.preferences.reminderCalendarIdentifier)
            data.preferences.reminderCalendarIdentifier = identifier
            data.preferences.reminderAlerts = true
            save()
            notificationStatus = "Reminders is connected. Send a test notification, then check your locked iPhone after two minutes."
        } catch {
            notificationError = error.localizedDescription
        }
    }

    func deliverAlert(trip: TrackedTrip, total: Int, reason: String) async {
        let title = "\(trip.name): \(money(total))"
        let body = "\(reason). Total for \(trip.query.travelerCount) traveler\(trip.query.travelerCount == 1 ? "" : "s")."
        await sendNotification(title: title, body: body, tripID: trip.id)
    }

    func testNotification() async {
        if data.preferences.macAlerts { await requestNotificationPermission() }
        await sendNotification(title: "Boschert Trip Tracker · Test alert",
                               body: "This is a test trip-price alert. Mark this reminder complete after checking your iPhone.", tripID: nil)
    }

    func sendNotification(title: String, body: String, tripID: UUID?) async {
        notificationError = nil
        notificationStatus = nil
        var successes: [String] = []
        var failures: [String] = []
        if data.preferences.macAlerts {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                if let tripID { content.userInfo = ["tripID": tripID.uuidString] }
                do {
                    try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    successes.append("Mac notification sent.")
                } catch { failures.append("The Mac notification could not be delivered.") }
            } else { failures.append("Allow Boschert Trip Tracker in System Settings → Notifications to receive Mac alerts.") }
        }
        if data.preferences.reminderAlerts {
            do {
                let scheduled = try reminderService.schedule(title: title, body: body,
                    identifier: data.preferences.reminderCalendarIdentifier)
                successes.append("Reminder scheduled for \(scheduled.formatted(date: .omitted, time: .shortened)). Check that your iPhone shows the alert at that time.")
            } catch { failures.append(error.localizedDescription) }
        }
        notificationStatus = successes.isEmpty ? nil : successes.joined(separator: " ")
        notificationError = failures.isEmpty ? nil : failures.joined(separator: " ")
    }
}

@MainActor
private final class ReminderAlertService {
    private let store = EKEventStore()
    private let listName = "Boschert Trip Tracker"

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func isICloud(_ calendar: EKCalendar) -> Bool {
        // CalDAV alone also includes providers such as Google. Never silently
        // fall back to a local list, which cannot deliver alerts to the phone.
        calendar.source.sourceType == .calDAV &&
        calendar.source.title.localizedCaseInsensitiveContains("iCloud") &&
        calendar.allowedEntityTypes.contains(.reminder) && calendar.allowsContentModifications
    }

    private func connectedCalendar(identifier: String?) -> EKCalendar? {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let identifier, let calendar = store.calendar(withIdentifier: identifier),
              isICloud(calendar) else { return nil }
        return calendar
    }

    func isConnected(identifier: String?) -> Bool {
        connectedCalendar(identifier: identifier) != nil
    }

    func connect(identifier: String?) async throws -> String {
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            guard try await store.requestFullAccessToReminders() else {
                throw SetupError(message: "Allow Reminders access to set up iPhone alerts. You can change this in System Settings → Privacy & Security → Reminders.")
            }
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw SetupError(message: "Allow Boschert Trip Tracker in System Settings → Privacy & Security → Reminders, then reconnect.")
        }
        if let connected = connectedCalendar(identifier: identifier) { return connected.calendarIdentifier }
        let calendars = store.calendars(for: .reminder).filter(isICloud)
        guard let source = calendars.first?.source else {
            throw SetupError(message: "No writable iCloud Reminders list was found. Turn on Reminders in System Settings → your name → iCloud, open Reminders once, then reconnect. A local or Google list cannot be used for this setup.")
        }
        if let existing = calendars.first(where: { $0.title == listName }) { return existing.calendarIdentifier }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = listName
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    func schedule(title: String, body: String, identifier: String?) throws -> Date {
        // Scheduled checks never trigger a permission prompt or create a list.
        guard let calendar = connectedCalendar(identifier: identifier) else {
            throw SetupError(message: "The iPhone reminder could not be scheduled. Reconnect Reminders in Notifications & settings and check that iCloud Reminders is on.")
        }
        // Leave time for iCloud to copy the timed reminder to the phone. Saving
        // it locally is not confirmation that the phone received a notification.
        let fireDate = Date().addingTimeInterval(120)
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        var due = gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        due.calendar = gregorian
        due.timeZone = gregorian.timeZone
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = body
        reminder.startDateComponents = due
        reminder.dueDateComponents = due
        reminder.addAlarm(EKAlarm(absoluteDate: fireDate))
        try store.save(reminder, commit: true)
        return fireDate
    }
}
