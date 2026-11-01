import SwiftUI

struct AirportField: View {
    let title: String
    let airports: [Airport]
    @Binding var code: String
    @State private var text = ""
    @FocusState private var focused: Bool
    private var suggestions: [Airport] {
        let term = text.trimmingCharacters(in: .whitespaces).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard !term.isEmpty else { return Array(airports.filter(\.large).prefix(6)) }
        return Array(airports.filter {
            "\($0.code) \($0.city) \($0.name)".folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(term)
        }.sorted { left, right in
            if (left.code.lowercased() == term) != (right.code.lowercased() == term) { return left.code.lowercased() == term }
            return left.large && !right.large
        }.prefix(7))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("City, airport or code", text: $text).textFieldStyle(.roundedBorder)
                .focused($focused).accessibilityLabel(title)
                .onChange(of: text) { _, value in
                    if let selected = airports.first(where: { $0.code == code }), value == selected.label { return }
                    let candidate = value.trimmingCharacters(in: .whitespaces).uppercased()
                    code = candidate.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil ? candidate : ""
                }
                .onSubmit { if let first = suggestions.first { choose(first) } }
            if focused {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { airport in
                        Button { choose(airport) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(airport.label).fontWeight(.medium); Spacer(); Text(airport.country).foregroundStyle(.secondary) }
                                Text(airport.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { text = airports.first(where: { $0.code == code })?.label ?? code }
        .onChange(of: code) { _, value in
            if !focused { text = airports.first(where: { $0.code == value })?.label ?? value }
        }
    }
    func choose(_ airport: Airport) { code = airport.code; text = airport.label; focused = false }
}

struct TrackSelection: Identifiable {
    let id = UUID()
    var mode: TrackingMode
    var query: TripQuery
    var outbound: FlightOption
    var returning: FlightOption?
    var fare: Int
    var sourceURL: String
    var checkedAt: String
}

struct FlightSearchView: View {
    @ObservedObject var model: TrackerStore
    @State private var origin = ""
    @State private var destination = ""
    @State private var roundTrip = true
    @State private var departure = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
    @State private var returning = Calendar.current.date(byAdding: .day, value: 37, to: Date())!
    @State private var adults = 2
    @State private var children = 0
    @State private var cabin = "economy"
    @State private var stops = -1
    @State private var airlineText = ""
    @State private var selection: TrackSelection?
    @State private var sort = 0
    var query: TripQuery {
        TripQuery(origin: origin, destination: destination, departure: flightDay(departure),
            returnDate: roundTrip ? flightDay(returning) : nil, adults: adults, children: children,
            cabin: cabin, maxStops: stops < 0 ? nil : stops,
            airlines: airlineText.uppercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Find your next trip").font(.largeTitle.bold())
                    Text("Search flights here, then track the whole trip at your target price.").foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("Trip type", selection: $roundTrip) {
                            Text("Round trip").tag(true); Text("One way").tag(false)
                        }.pickerStyle(.segmented).frame(width: 260)
                        HStack(alignment: .top, spacing: 18) {
                            AirportField(title: "From", airports: model.airports, code: $origin)
                            AirportField(title: "To", airports: model.airports, code: $destination)
                        }
                        HStack(spacing: 22) {
                            DatePicker("Departure", selection: $departure, in: Date()..., displayedComponents: .date)
                            if roundTrip { DatePicker("Return", selection: $returning, in: departure..., displayedComponents: .date) }
                        }
                        HStack(spacing: 24) {
                            Stepper("Adults: \(adults)", value: $adults, in: 1...9)
                            Stepper("Children: \(children)", value: $children, in: 0...8)
                            Picker("Cabin", selection: $cabin) {
                                Text("Economy").tag("economy"); Text("Premium economy").tag("premium-economy")
                                Text("Business").tag("business"); Text("First").tag("first")
                            }
                        }
                        HStack(spacing: 24) {
                            Picker("Stops", selection: $stops) {
                                Text("Any").tag(-1); Text("Nonstop").tag(0); Text("Up to 1 stop").tag(1); Text("Up to 2 stops").tag(2)
                            }.frame(maxWidth: 250)
                            TextField("Airline codes, optional: UA, AA, DL", text: $airlineText).textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Button { Task { await model.search(query) } } label: { Label("Search flights", systemImage: "magnifyingglass") }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(model.busy || origin.count != 3 || destination.count != 3 || origin == destination || adults + children > 9)
                            if model.busy { ProgressView().controlSize(.small); Text("Checking live fares…").foregroundStyle(.secondary) }
                            Spacer()
                            Text("USD · taxes included · total for everyone").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(14)
                }
                if let result = model.searchResult {
                    resultView(result)
                } else if !model.busy {
                    ContentUnavailableView("Your trip starts here", systemImage: "airplane.departure",
                        description: Text("Choose your airports and dates to compare live fares. No account is needed."))
                }
                Text("Times are local to each airport. Bag costs can be added as a separate trip-wide estimate when you start tracking.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(30)
        }
        .sheet(item: $selection) { TrackTripSheet(model: model, selection: $0) }
        .onChange(of: departure) { _, value in if returning < value { returning = value } }
        .onAppear {
            if let q = model.searchResult?.query {
                origin = q.origin; destination = q.destination; roundTrip = q.isRoundTrip
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
                departure = formatter.date(from: q.departure) ?? departure
                returning = q.returnDate.flatMap { formatter.date(from: $0) } ?? returning
                adults = q.adults; children = q.children; cabin = q.cabin; stops = q.maxStops ?? -1
                airlineText = q.airlines.joined(separator: ", ")
            }
        }
    }

    @ViewBuilder func resultView(_ result: FlightSearch) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.stage == "return" ? "Choose your return flight" : "\(result.options.count) departure options").font(.title2.bold())
                    Text("\(model.airportLabel(result.query.origin)) → \(model.airportLabel(result.query.destination)) · \(readableDay(result.query.departure))" +
                        (result.query.returnDate.map { " – \(readableDay($0))" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Sort", selection: $sort) { Text("Cheapest").tag(0); Text("Shortest").tag(1) }.frame(width: 150)
            }
            if result.stage == "return", let outbound = result.outbound {
                GroupBox("Your departure") {
                    HStack {
                        Text("\(outbound.flightNumbers) · \(outbound.departureTime) → \(outbound.arrivalTime)")
                        Spacer()
                        Button("Change departure") { Task { await model.search(result.query) } }.disabled(model.busy)
                    }.padding(8)
                }
                Text("Prices below cover both directions for all \(result.query.travelerCount) travelers. They are not extra return-flight charges.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let cheapest = result.options.first {
                HStack(spacing: 18) {
                    Image(systemName: "bell.badge").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Track the cheapest matching trip").font(.headline)
                        Text("Currently \(money(cheapest.totalCents)) for everyone. Any matching flight can trigger a price alert.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Track cheapest trip") {
                        selection = TrackSelection(mode: .cheapest, query: result.query, outbound: cheapest,
                            returning: nil, fare: cheapest.totalCents, sourceURL: result.searchURL, checkedAt: result.checkedAt)
                    }.buttonStyle(.borderedProminent).disabled(model.busy || !model.storageAvailable)
                }.padding(18).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if result.options.isEmpty {
                ContentUnavailableView("No matching flights", systemImage: "airplane",
                    description: Text("Try another date or broaden the stops and airline filters."))
            }
            let options = sort == 1 ? result.options.sorted { $0.durationMinutes < $1.durationMinutes } : result.options
            LazyVStack(spacing: 12) {
                ForEach(options) { option in
                    FlightCard(option: option, priceLabel: result.query.isRoundTrip ? "round-trip total" : "one-way total",
                               travelers: result.query.travelerCount, isFromPrice: result.query.isRoundTrip && result.stage == "departure") {
                        if result.query.isRoundTrip && result.stage == "departure" {
                            Task { await model.search(result.query, outbound: option) }
                        } else {
                            selection = TrackSelection(mode: .selected, query: result.query,
                                outbound: result.outbound ?? option, returning: result.stage == "return" ? option : nil,
                                fare: option.totalCents, sourceURL: result.searchURL, checkedAt: result.checkedAt)
                        }
                    } actionLabel: { result.query.isRoundTrip && result.stage == "departure" ? "Choose return" : "Track these flights" }
                    .disabled(model.busy)
                }
            }
        }
    }
}

struct FlightCard: View {
    let option: FlightOption
    var priceLabel: String
    var travelers: Int
    var isFromPrice = false
    let action: () -> Void
    let actionLabel: () -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.airlines.joined(separator: ", ")).font(.headline)
                    Text(option.flightNumbers).font(.caption).foregroundStyle(.secondary)
                }.frame(width: 140, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(option.departureTime) → \(option.arrivalTime)").font(.title3.weight(.semibold))
                    Text(option.route).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text((isFromPrice ? "from " : "") + money(option.totalCents)).font(.title3.bold())
                    Text("\(priceLabel) · \(travelers) travelers").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(option.durationLabel) · \(option.stopsLabel)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(actionLabel(), action: action).buttonStyle(.bordered)
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

struct TrackTripSheet: View {
    @ObservedObject var model: TrackerStore
    let selection: TrackSelection
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var baggage = "0"
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Start tracking this trip").font(.title2.bold())
            Text(selection.mode == .cheapest ? "Watch the cheapest flight combination matching this search." : "Watch the selected flights together as one trip.")
                .foregroundStyle(.secondary)
            TextField("Trip name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                VStack(alignment: .leading) { Text("Target total, optional"); TextField("e.g. 600", text: $target).textFieldStyle(.roundedBorder) }
                VStack(alignment: .leading) { Text("Estimated bags for entire trip"); TextField("0", text: $baggage).textFieldStyle(.roundedBorder) }
            }
            Text("Airfare: \(money(selection.fare)) for all \(selection.query.travelerCount) travelers. Bags are a manual estimate added once for the whole trip.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Alerts: below your target and every new lowest price, including a $1 drop. The first price establishes your baseline.")
                .font(.callout)
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Track trip") { save() }.buttonStyle(.borderedProminent).disabled(saving || !model.storageAvailable)
            }
        }.padding(28).frame(width: 540)
        .onAppear { name = "\(model.airportLabel(selection.query.origin)) → \(model.airportLabel(selection.query.destination))" }
    }
    func save() {
        let noTarget = target.trimmingCharacters(in: .whitespaces).isEmpty
        guard let bags = parseMoney(baggage), noTarget || (parseMoney(target) ?? 0) > 0 else {
            error = "Enter a valid bag estimate and a positive target, or leave the target blank."
            return
        }
        guard let observedAt = trackerTimestamp(selection.checkedAt), Date().timeIntervalSince(observedAt) < 15 * 60 else {
            error = "This quote is more than 15 minutes old. Search again to start with a fresh price."
            return
        }
        saving = true
        Task {
            var source = selection.sourceURL
            if selection.mode == .selected, let url = await model.selectedBookingURL(query: selection.query,
                    outbound: selection.outbound, returning: selection.returning) { source = url }
            await model.addTrip(name: name, mode: selection.mode, query: selection.query, outbound: selection.outbound,
                returning: selection.returning, fare: selection.fare, target: noTarget ? nil : parseMoney(target),
                baggage: bags, sourceURL: source, observedAt: observedAt)
            saving = false
            dismiss()
        }
    }
}
