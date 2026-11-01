import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class TrackerAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: TrackerStore?
    var showWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplane", accessibilityDescription: "Boschert Trip Tracker")
        let menu = NSMenu()
        for (title, action, key) in [("Open Boschert Trip Tracker", #selector(openTracker), ""),
                                     ("Check tracked trips now", #selector(checkTrips), ""),
                                     ("Quit Boschert Trip Tracker", #selector(quitTracker), "q")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openTracker() }
        return true
    }
    @objc func openTracker() { showWindow?(); NSApplication.shared.activate(ignoringOtherApps: true) }
    @objc func checkTrips() { Task { await store?.checkDueTrips(force: true) } }
    @objc func quitTracker() { NSApplication.shared.terminate(nil) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = response.notification.request.content.userInfo["tripID"] as? String
        Task { @MainActor in
            if let value, let id = UUID(uuidString: value) { self.store?.page = .trip(id) }
            self.openTracker()
        }
        completionHandler()
    }
}

struct BrandMark: View {
    var height: CGFloat = 40
    var body: some View {
        if let url = Bundle.main.url(forResource: "BoschertTechnologiesMark", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(.primary)
                .frame(width: height * 0.49, height: height).accessibilityLabel("Boschert Technologies logo")
        }
    }
}

struct TrackerRootView: View {
    @ObservedObject var model: TrackerStore
    let delegate: TrackerAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BrandMark()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Boschert").font(.title3.bold())
                        Text("Trip Tracker").font(.headline)
                        Text("Boschert Technologies").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 18).padding(.top, 16)
                List(selection: $model.page) {
                    NavigationLink(value: TrackerPage.search) { Label("Search flights", systemImage: "magnifyingglass") }
                    Section("Tracked trips") {
                        if model.activeTrips.isEmpty { Text("Your saved trips appear here").font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.activeTrips) { trip in
                            NavigationLink(value: TrackerPage.trip(trip.id)) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(trip.name).lineLimit(1)
                                    HStack {
                                        Text("\(trip.query.origin) → \(trip.query.destination)")
                                        Spacer()
                                        if trip.isPaused { Image(systemName: "pause.fill") }
                                        else if let price = trip.currentTotal { Text(money(price)) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                    Section {
                        NavigationLink(value: TrackerPage.settings) { Label("Notifications & settings", systemImage: "gearshape") }
                        NavigationLink(value: TrackerPage.health) { Label("Flight data status", systemImage: "waveform.path.ecg") }
                        NavigationLink(value: TrackerPage.archive) { Label("Archived trips", systemImage: "archivebox") }
                    }
                }.listStyle(.sidebar)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding().background(.orange.opacity(0.08))
                }
                switch model.page ?? .search {
                case .search: FlightSearchView(model: model)
                case .trip(let id):
                    if let trip = model.trip(id) { TrackedTripView(model: model, trip: trip) }
                    else { ContentUnavailableView("Trip unavailable", systemImage: "airplane") }
                case .settings: TrackerSettingsView(model: model)
                case .health: StatusView(model: model.health)
                case .archive:
                    List {
                        ForEach(model.data.trips.filter(\.archived)) { trip in
                            HStack { Text(trip.name); Spacer(); Button("Restore") { model.archive(trip.id, archived: false) } }
                        }
                    }.navigationTitle("Archived trips")
                }
            }
        }
        .frame(minWidth: 1050, minHeight: 750)
        .onAppear { delegate.store = model; delegate.showWindow = { openWindow(id: "main") } }
    }
}

@main
struct BoschertTripTrackerApp: App {
    @NSApplicationDelegateAdaptor(TrackerAppDelegate.self) private var delegate
    @StateObject private var model = TrackerStore()
    var body: some Scene {
        WindowGroup("Boschert Trip Tracker", id: "main") { TrackerRootView(model: model, delegate: delegate) }
            .defaultSize(width: 1220, height: 880)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Boschert Trip Tracker") {
                        NSApplication.shared.orderFrontStandardAboutPanel(options: [
                            .applicationName: "Boschert Trip Tracker", .applicationVersion: "0.2.1",
                            .credits: NSAttributedString(string: "Boschert Technologies\nPrivate flight-price tracking")])
                    }
                }
            }
    }
}
