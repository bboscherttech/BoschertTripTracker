import AppKit
import Charts
import SwiftUI

struct TrackedTripView: View {
    @ObservedObject var model: TrackerStore
    let trip: TrackedTrip
    @State private var editing = false
    @State private var archivePrompt = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(trip.name).font(.largeTitle.bold())
                        Text("\(trip.query.tripLabel) · \(readableDay(trip.query.departure))" + (trip.query.returnDate.map { " – \(readableDay($0))" } ?? "") +
                             " · \(trip.query.travelerCount) travelers").foregroundStyle(.secondary)
                        Label(trip.trackingLabel, systemImage: trip.mode == .cheapest ? "sparkle.magnifyingglass" : "pin.fill")
                            .font(.callout).foregroundStyle(.teal)
                    }
                    Spacer()
                    Button("Edit target & bags") { editing = true }
                }
                HStack(spacing: 16) {
                    priceTile("Current total", value: trip.currentTotal, caption: trip.lastError == nil ? "Last successful quote" : "Last known price", color: .primary)
                    priceTile("Lowest seen", value: trip.lowestTotal, caption: "Since tracking began", color: .teal)
                    priceTile("Your target", value: trip.targetCents, caption: trip.targetCents == nil ? "New-low alerts are active" : "Alert below this total", color: .primary)
                }
                if let error = trip.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    if trip.isPastDeparture { Label("Departure date has passed · checks stopped", systemImage: "calendar.badge.checkmark").foregroundStyle(.secondary) }
                    else if trip.isPaused { Label("Tracking paused", systemImage: "pause.circle").foregroundStyle(.secondary) }
                    else { Label("Checking every \(model.data.preferences.intervalMinutes) minutes", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                    Spacer()
                    if model.checkingTrip == trip.id { ProgressView().controlSize(.small) }
                    Button("Check now") { Task { await model.refreshTrip(trip.id) } }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || trip.isPastDeparture)
                    Button(trip.isPaused ? "Resume" : "Pause") { model.togglePause(trip.id) }.disabled(trip.isPastDeparture)
                }
                if let checked = trip.lastSuccess {
                    Text("Last successful check: \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("Trip price history") {
                    VStack(alignment: .leading, spacing: 12) {
                        Chart {
                            ForEach(trip.history) { point in
                                LineMark(x: .value("Checked", point.at), y: .value("Total", Double(point.fareCents + trip.baggageCents) / 100))
                                    .foregroundStyle(Color.teal).interpolationMethod(.linear)
                                PointMark(x: .value("Checked", point.at), y: .value("Total", Double(point.fareCents + trip.baggageCents) / 100))
                                    .foregroundStyle(Color.teal)
                            }
                            if let target = trip.targetCents {
                                RuleMark(y: .value("Target", Double(target) / 100)).foregroundStyle(.secondary)
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                            }
                        }.frame(height: 200)
                            .chartYAxis {
                                AxisMarks { value in
                                    AxisGridLine()
                                    AxisValueLabel { if let amount = value.as(Double.self) { Text(money(Int((amount * 100).rounded()))) } }
                                }
                            }
                        Text("Totals cover everyone, with your \(money(trip.baggageCents)) trip-wide bag estimate added to each quote.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                if let outbound = trip.displayOutbound {
                    itinerary(outbound, title: trip.mode == .cheapest ? "Latest cheapest departure" : "Selected departure")
                }
                if let returning = trip.displayReturn { itinerary(returning, title: "Selected return") }
                else if trip.query.isRoundTrip && trip.mode == .cheapest {
                    Text("This trip follows the lowest complete round-trip fare matching your search. Select specific departure and return flights from Search flights if you want to pin an itinerary.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if let value = trip.bookingURL, let url = URL(string: value) {
                        Link("View booking options", destination: url)
                    }
                    Spacer()
                    Button("Archive trip", role: .destructive) { archivePrompt = true }
                }
                DisclosureGroup("Recent checks") {
                    VStack(spacing: 10) {
                        ForEach(Array(trip.history.suffix(30).reversed())) { point in
                            HStack { Text(point.at.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(money(point.fareCents + trip.baggageCents)).monospacedDigit() }
                        }
                    }.padding(.top, 12)
                }
                if !trip.alerts.isEmpty {
                    GroupBox("Price alerts") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(trip.alerts.suffix(15).reversed())) { alert in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(alert.reason).fontWeight(.medium)
                                        Text(alert.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(money(alert.totalCents)).font(.headline)
                                }
                            }
                        }.padding(12)
                    }
                }
                if let error = model.notificationError { Label(error, systemImage: "bell.slash").font(.callout).foregroundStyle(.orange) }
            }.padding(30)
        }
        .sheet(isPresented: $editing) { EditTripSheet(model: model, trip: trip) }
        .confirmationDialog("Archive \(trip.name)?", isPresented: $archivePrompt) {
            Button("Archive trip") { model.archive(trip.id) }
        } message: { Text("Price checks stop. You can restore the trip and its history from Archived trips.") }
    }
    func priceTile(_ title: String, value: Int?, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value.map(money) ?? "Not set").font(.system(size: 27, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    func itinerary(_ option: FlightOption, title: String) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(option.segments.enumerated()), id: \.offset) { _, segment in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(segment.flightNumber) · \(segment.origin) → \(segment.destination)").fontWeight(.medium)
                            Text("\(readableDay(segment.date)) · \(segment.aircraft)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(segment.departure.suffix(5)) → \(segment.arrival.suffix(5))").monospacedDigit()
                            if String(segment.arrival.prefix(10)) != segment.date {
                                Text("Arrives \(readableDay(String(segment.arrival.prefix(10))))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("\(option.durationLabel) · \(option.stopsLabel) · times local to each airport").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}

struct EditTripSheet: View {
    @ObservedObject var model: TrackerStore
    let trip: TrackedTrip
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var baggage = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit trip").font(.title2.bold())
            TextField("Trip name", text: $name).textFieldStyle(.roundedBorder)
            LabeledContent("Target total, optional") { TextField("No target", text: $target).textFieldStyle(.roundedBorder) }
            LabeledContent("Bags for the entire trip") { TextField("0", text: $baggage).textFieldStyle(.roundedBorder) }
            Text("Changing bags adjusts the displayed history consistently. It does not create a new fare drop.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save changes") {
                    let empty = target.trimmingCharacters(in: .whitespaces).isEmpty
                    guard let bags = parseMoney(baggage), empty || (parseMoney(target) ?? 0) > 0 else { error = "Enter valid dollar amounts."; return }
                    model.updateTrip(trip.id, name: name, target: empty ? nil : parseMoney(target), baggage: bags)
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 500)
        .onAppear {
            name = trip.name
            target = trip.targetCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
            baggage = String(format: "%.2f", Double(trip.baggageCents) / 100)
        }
    }
}
