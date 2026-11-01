import AppKit
import SwiftUI

struct TrackerSettingsView: View {
    @ObservedObject var model: TrackerStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Notifications & settings").font(.largeTitle.bold())
                GroupBox("Price checks") {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Check tracked trips", selection: $model.data.preferences.intervalMinutes) {
                            Text("Every 15 minutes").tag(15); Text("Every 30 minutes").tag(30)
                            Text("Every hour").tag(60); Text("Every 3 hours").tag(180); Text("Every 6 hours").tag(360)
                        }
                        Text("Checks continue when the window is closed, while the menu-bar app is running. Paused and past-departure trips are skipped.")
                            .font(.callout).foregroundStyle(.secondary)
                        Toggle("Keep the Mac awake when its screen turns off", isOn: $model.data.preferences.preventIdleSleep)
                        Text("This prevents idle sleep while an active trip is tracked. Closing the lid normally causes system sleep; closed-lid mode needs a separate keep-awake setup.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Mac notifications") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Notify on this Mac", isOn: $model.data.preferences.macAlerts)
                        Text("Alerts are sent when a fare falls below your target or reaches a new recorded low. A $1 drop counts; an unchanged price produces no repeat alert.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Allow Mac notifications") { Task { await model.requestNotificationPermission() } }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("iPhone alerts · built-in Reminders") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Use the Reminders app on your iPhone for free price-drop notifications. No additional phone app, SMS service, or developer membership is needed.")
                            .font(.callout)
                        Text("1. Turn on iCloud Reminders on this Mac and your iPhone using the same Apple account.\n2. Set up Reminders alerts below and allow access when asked.\n3. Send a test notification, lock your iPhone, and wait two minutes.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(model.data.preferences.reminderCalendarIdentifier == nil ? "Set up Reminders alerts" : "Reconnect Reminders") {
                                Task { await model.connectReminders() }
                            }.disabled(model.connectingReminders || !model.storageAvailable)
                            if model.connectingReminders { ProgressView().controlSize(.small) }
                            Button("Open Reminders") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) }
                        }
                        Text(model.remindersConnectionDescription).font(.callout).foregroundStyle(.secondary)
                        Toggle("Send price alerts to my iPhone through Reminders", isOn: $model.data.preferences.reminderAlerts)
                            .disabled(!model.remindersConnected && !model.data.preferences.reminderAlerts)
                        Text("Alerts appear in a Boschert Trip Tracker reminder list and can be marked complete. Each is scheduled two minutes ahead to allow time to sync. Enable Reminders notifications on your iPhone and verify the test alert before relying on this method.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Alert text is stored in your existing iCloud account. Trip tracking and price history stay on this Mac. Delivery depends on iCloud syncing; this is a Reminders notification, not a text message.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Apple's iCloud Reminders setup", destination: URL(string: "https://support.apple.com/guide/icloud/set-up-reminders-mmbf52194b5a/icloud")!)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Send test notification") { Task { await model.testNotification() } }.buttonStyle(.borderedProminent)
                        .disabled((!model.data.preferences.macAlerts && !model.data.preferences.reminderAlerts) || model.connectingReminders)
                    Spacer()
                }
                if let status = model.notificationStatus { Label(status, systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error = model.notificationError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text("Boschert Trip Tracker 0.2.1 · Boschert Technologies\nLive fares are checked through an unofficial Google Flights connector. Booking prices and availability can change.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(30)
        }
        .onChange(of: model.data.preferences.intervalMinutes) { model.preferencesChanged() }
        .onChange(of: model.data.preferences.macAlerts) { model.preferencesChanged() }
        .onChange(of: model.data.preferences.reminderAlerts) { model.preferencesChanged() }
        .onChange(of: model.data.preferences.preventIdleSleep) { model.preferencesChanged() }
    }
}
