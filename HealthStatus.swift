import AppKit
import SwiftUI

struct HealthEvent: Decodable {
    var at: String
    var kind: String
    var detail: String
}

struct HealthState: Decodable {
    var connectorVersion: String?
    var latestConnectorVersion: String?
    var updateAvailable: Bool?
    var status: String
    var detail: String
    var lastSuccess: String?
    var lastAttempt: String?
    var lastUpdateCheck: String?
    var updateCheckError: String?
    var observedGoogleBuild: String?
    var lastSuccessfulGoogleBuild: String?
    var consecutiveFormatFailures: Int
    var pricesFresh: Bool
    var events: [HealthEvent]
}

struct WorkerReport: Decodable { var health: HealthState }

func runWorker(executable: URL, arguments: [String], inputData: Data? = nil) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    let input = Pipe()
    if inputData != nil { process.standardInput = input }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    if let inputData { input.fileHandleForWriting.write(inputData); try input.fileHandleForWriting.close() }
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    return data
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var health: HealthState?
    @Published var busy = false
    @Published var error: String?
    private let state: URL

    init(stateURL: URL? = nil) {
        if let stateURL { state = stateURL; return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--state"), arguments.indices.contains(index + 1) {
            state = URL(fileURLWithPath: arguments[index + 1])
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            state = support.appendingPathComponent("Boschert Trip Tracker/health.json")
            // Preserve the history produced by the first maintenance preview.
            let legacyState = support.appendingPathComponent("Fare Watch Preview/health.json")
            if !FileManager.default.fileExists(atPath: state.path),
               FileManager.default.fileExists(atPath: legacyState.path) {
                do {
                    try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: legacyState, to: state)
                } catch {
                    // The legacy copy remains intact; a manual check can initialize new history.
                }
            }
        }
    }

    func check(live: Bool = false, updates: Bool = false) {
        guard !busy else { return }
        guard let resources = Bundle.main.resourceURL else { return }
        let executable = resources.appendingPathComponent("worker/triptracker-worker")
        var arguments = ["--state", state.path]
        if updates { arguments += ["--force-update-check"] }
        if live {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let departure = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
            let returning = Calendar.current.date(byAdding: .day, value: 37, to: Date())!
            arguments += ["--origin", "ORD", "--destination", "BOS", "--departure", formatter.string(from: departure),
                          "--return-date", formatter.string(from: returning), "--adults", "2", "--check-updates"]
        }
        busy = true
        error = nil
        Task {
            do {
                let workerArguments = arguments
                let data = try await Task.detached {
                    try runWorker(executable: executable, arguments: workerArguments)
                }.value
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                health = try decoder.decode(WorkerReport.self, from: data).health
            } catch {
                self.error = "The status check could not finish. Existing health history has been preserved."
            }
            busy = false
        }
    }

    var title: String {
        if error != nil { return "The status check could not finish" }
        guard let health else { return "Ready for the first check" }
        switch health.status {
        case "working": return health.pricesFresh ? "Flight data is working" : "Flight data needs a fresh check"
        case "no_results": return "Lookup worked · no matching flights"
        case "maintenance_suggested": return "Maintenance may be needed"
        case "response_unrecognized": return "Flight data needs another check"
        case "connection_problem": return "Connection problem"
        case "access_limited": return "Google limited this lookup"
        case "source_unavailable": return "Flight source is unavailable"
        case "local_component_problem": return "Search component needs attention"
        default: return "Ready for the first check"
        }
    }

    var color: Color {
        if error != nil { return .orange }
        if health?.status == "working", health?.pricesFresh == false { return .secondary }
        switch health?.status {
        case "working", "no_results": return .green
        case "maintenance_suggested", "local_component_problem": return .orange
        default: return .secondary
        }
    }
}

func displayDate(_ value: String?) -> String {
    guard let value else { return "Not checked yet" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value) else { return value }
    return date.formatted(date: .abbreviated, time: .shortened)
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    if let url = Bundle.main.url(forResource: "BoschertTechnologiesMark", withExtension: "png"),
                       let mark = NSImage(contentsOf: url) {
                        Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(.primary).frame(width: 30, height: 62)
                            .accessibilityLabel("Boschert Technologies logo")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Flight data status").font(.system(size: 29, weight: .bold))
                        Text("Boschert Technologies").font(.subheadline).foregroundStyle(.secondary)
                        Text("Connector health and maintenance").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.title, systemImage: "circle.fill").font(.title3.bold()).foregroundStyle(model.color)
                        Text(model.health?.detail ?? "Run a live sample search to check whether flight data can be read.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let error = model.error { Text(error).foregroundStyle(.orange) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                GroupBox("Search component") {
                    VStack(spacing: 14) {
                        row("Installed connector", "fast-flights " + (model.health?.connectorVersion ?? "—"))
                        row("Latest checked release", model.health?.latestConnectorVersion ?? "Not checked yet")
                        row("Update status", model.health?.updateAvailable == true ? "Update available" :
                            (model.health?.latestConnectorVersion == nil ? "Not checked yet" : "Current"))
                        row("Last release check", displayDate(model.health?.lastUpdateCheck))
                        if let message = model.health?.updateCheckError {
                            Text(message).foregroundStyle(.secondary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(12)
                }
                GroupBox("Compatibility") {
                    VStack(spacing: 14) {
                        row("Last successful flight check", displayDate(model.health?.lastSuccess))
                        row("Last attempted flight check", displayDate(model.health?.lastAttempt))
                        row("Google API version", "Not published")
                        DisclosureGroup("Google build details") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.health?.observedGoogleBuild ?? model.health?.lastSuccessfulGoogleBuild ?? "Not observed yet")
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text("This internal build label helps diagnose changes. A changed label alone does not mean the app needs maintenance.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }
                    }.padding(12)
                }
                if let events = model.health?.events, !events.isEmpty {
                    DisclosureGroup("Recent status changes") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(events.suffix(5).reversed().enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.detail).font(.callout)
                                    Text(displayDate(event.at)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    }
                }
                HStack {
                    Button("Check live sample") { model.check(live: true) }.buttonStyle(.borderedProminent)
                    Button("Check for connector updates") { model.check(updates: true) }
                    Spacer()
                }.disabled(model.busy)
                Text("The sample checks Chicago (ORD) → Boston (BOS) for two adults, departing in 30 days and returning a week later. This diagnostic sample does not change your tracked trips.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(30)
        }.frame(minWidth: 670, minHeight: 720).background(Color(nsColor: .windowBackgroundColor))
    }

    func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

