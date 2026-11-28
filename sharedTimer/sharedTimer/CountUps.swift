//
//  CountUps.swift
//  sharedTimer
//
//  N6 "days since" and N7 stopwatch (owner's picks A / A, 2026-11-28,
//  https://claude.ai/artifact/Ah5VuSJMj9Akm63cBUKe38). Things that count up and never
//  end, so they are deliberately NOT TimerPayloads: the timer code assumes a finish
//  (24 h prune, History, overtime, alarms, widgets, Watch, Siri, Spotlight, sharing,
//  iCloud sync). Main app only, kept on this iPhone (App Group blob), never in a link,
//  iCloud, widgets, the Watch or Siri.
//

import SwiftUI

/// A count of calendar days since a date (midnight to midnight in the phone's zone).
struct DaysSince: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var label: String
    /// The day it counts from (its start of day when created).
    var startDate: Date

    /// Whole calendar days from the start day to `date`'s day — so it ticks over at
    /// midnight, and a DST day still counts as one.
    func days(at date: Date = Date(), calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: startDate), to = calendar.startOfDay(for: date)
        return max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    }

    /// "Today", "12 days", or "1 yr, 2 mths" past a year — localized by the system's
    /// formatter (plurals included).
    func countText(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let days = days(at: date, calendar: calendar)
        guard days > 0 else { return String(localized: "Today") }
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        if days < 365 {
            formatter.allowedUnits = [.day]
            formatter.unitsStyle = .full
            return formatter.string(from: DateComponents(day: days)) ?? "\(days)"
        }
        let parts = calendar.dateComponents([.year, .month], from: calendar.startOfDay(for: startDate), to: calendar.startOfDay(for: date))
        formatter.allowedUnits = [.year, .month]
        formatter.unitsStyle = .short
        return formatter.string(from: DateComponents(year: parts.year, month: parts.month)) ?? "\(days)"
    }
}

/// One stopwatch, stored as a start time plus what ran before, so it survives the app
/// being closed or the phone restarting. Pure, date-parameterized.
struct Stopwatch: Codable, Equatable {
    var startedAt: Date?
    var accumulated: TimeInterval = 0
    /// Each lap's split: the elapsed time when Lap was tapped.
    var splits: [TimeInterval] = []

    var isRunning: Bool { startedAt != nil }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    func started(at date: Date = Date()) -> Stopwatch {
        guard startedAt == nil else { return self }
        var next = self; next.startedAt = date; return next
    }

    func paused(at date: Date = Date()) -> Stopwatch {
        guard startedAt != nil else { return self }
        var next = self; next.accumulated = elapsed(at: date); next.startedAt = nil; return next
    }

    func lapped(at date: Date = Date()) -> Stopwatch {
        guard isRunning else { return self }
        var next = self; next.splits.append(elapsed(at: date)); return next
    }

    /// Each finished lap's own length, oldest first.
    var lapLengths: [TimeInterval] {
        zip(splits, [0] + splits).map { $0 - $1 }
    }

    /// The running lap's length so far.
    func currentLap(at date: Date = Date()) -> TimeInterval { elapsed(at: date) - (splits.last ?? 0) }

    /// "04:12.37", hours shown once reached.
    static func text(_ seconds: TimeInterval, hundredths: Bool = true) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600, m = (Int(total) % 3600) / 60, s = Int(total) % 60
        let cs = Int((total - floor(total)) * 100)
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return hundredths ? base + String(format: ".%02d", cs) : base
    }
}

struct CountUps: Codable, Equatable {
    var daysSince: [DaysSince] = []
    var stopwatch: Stopwatch?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysSince = (try? c.decodeIfPresent([DaysSince].self, forKey: .daysSince)) ?? []
        stopwatch = (try? c.decodeIfPresent(Stopwatch.self, forKey: .stopwatch)) ?? nil
    }
}

enum CountUpStore {
    static let changed = Notification.Name("SharedTimerCountUpsChanged")
    private static let key = "countUps.v1"
    private static let lock = NSLock()
    nonisolated(unsafe) static var defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lokesh.sharedTimer")

    static func load() -> CountUps {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Read-modify-write; a stored blob this build can't decode is left untouched.
    static func update(_ change: (inout CountUps) -> Void) {
        lock.lock()
        if let data = defaults?.data(forKey: key), (try? JSONDecoder().decode(CountUps.self, from: data)) == nil {
            lock.unlock(); return
        }
        var value = read()
        let before = value
        change(&value)
        if value != before, let data = try? JSONEncoder().encode(value) { defaults?.set(data, forKey: key) }
        lock.unlock()
        if value != before { DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) } }
    }

    private static func read() -> CountUps {
        guard let data = defaults?.data(forKey: key) else { return CountUps() }
        return (try? JSONDecoder().decode(CountUps.self, from: data)) ?? CountUps()
    }
}

// MARK: - Views

private let sinceSky = LinearGradient(colors: [Color(red: 0.06, green: 0.19, blue: 0.17), Color(red: 0.18, green: 0.49, blue: 0.43), Color(red: 0.62, green: 0.88, blue: 0.78)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
private let stopwatchSky = LinearGradient(colors: [Color(red: 0.12, green: 0.23, blue: 0.37), Color(red: 0.42, green: 0.56, blue: 0.75), Color(red: 0.95, green: 0.79, blue: 0.63)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)

/// A list card for a count-up: the app's card shape with its own sky.
struct CountUpCard: View {
    let title: String
    let big: String
    let detail: String
    let sky: LinearGradient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).skyLabel(12).lineLimit(1).foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline) {
                Text(big).skyDigits(34, weight: .regular).lineLimit(1).minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Text(detail).skyLabel(10).lineLimit(1).foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(sky, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(big), \(detail)")
        .accessibilityAddTraits(.isButton)
    }

    static func days(_ item: DaysSince, at date: Date) -> CountUpCard {
        CountUpCard(title: item.label, big: item.countText(at: date),
                    detail: String(localized: "Since \(item.startDate.formatted(date: .abbreviated, time: .omitted))"), sky: sinceSky)
    }

    static func stopwatch(_ watch: Stopwatch, at date: Date) -> CountUpCard {
        CountUpCard(title: String(localized: "Stopwatch"), big: Stopwatch.text(watch.elapsed(at: date), hundredths: false),
                    detail: watch.isRunning ? String(localized: "Running") : String(localized: "Paused"), sky: stopwatchSky)
    }
}

/// New "Days Since…": a name and a day, today or earlier.
struct NewDaysSinceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var day = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                        .accessibilityIdentifier("daysSinceLabel")
                    DatePicker("Since", selection: $day, in: ...Date(), displayedComponents: .date)
                } footer: {
                    Text("Counts whole days, ticking over at midnight. Kept on this iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle("Days Since")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        let item = DaysSince(label: trimmed.isEmpty ? String(localized: "Days Since") : String(trimmed.prefix(200)),
                                             startDate: Calendar.current.startOfDay(for: day))
                        CountUpStore.update { $0.daysSince.append(item) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("daysSinceStart")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// A days-since count on its own: Start Over (from today), rename, delete.
struct DaysSinceDetail: View {
    @Environment(\.dismiss) private var dismiss
    let itemID: String
    @State private var countUps = CountUpStore.load()
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    private var item: DaysSince? { countUps.daysSince.first { $0.id == itemID } }

    var body: some View {
        ZStack {
            sinceSky.ignoresSafeArea()
            if let item {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 10) {
                        Spacer()
                        Text(item.label).skyLabel(12).foregroundStyle(.white.opacity(0.85))
                        Text(item.countText(at: context.date)).skyDigits(64, weight: .thin)
                            .lineLimit(1).minimumScaleFactor(0.4).padding(.horizontal, 24)
                        Text("Since \(item.startDate.formatted(date: .complete, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        HStack(spacing: 12) {
                            Button("Start Over") {
                                CountUpStore.update { c in
                                    if let i = c.daysSince.firstIndex(where: { $0.id == itemID }) { c.daysSince[i].startDate = Calendar.current.startOfDay(for: Date()) }
                                }
                                countUps = CountUpStore.load()
                            }
                            .buttonStyle(.glassPill)
                            .accessibilityIdentifier("daysSinceStartOver")
                            Button("Rename") { newName = item.label; renaming = true }
                                .buttonStyle(.glassPill)
                        }
                        Button("Delete", role: .destructive) { confirmingDelete = true }
                            .buttonStyle(.glassPill)
                            .padding(.bottom, 24)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(16)
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Label", text: $newName)
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                CountUpStore.update { c in
                    if let i = c.daysSince.firstIndex(where: { $0.id == itemID }) { c.daysSince[i].label = String(trimmed.prefix(200)) }
                }
                countUps = CountUpStore.load()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(String(localized: "Delete this count?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                CountUpStore.update { $0.daysSince.removeAll { $0.id == itemID } }
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// The stopwatch screen: hundredths only here, laps with the fastest and slowest marked.
struct StopwatchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var watch: Stopwatch = CountUpStore.load().stopwatch ?? Stopwatch()

    private func save(_ next: Stopwatch?) {
        if let next { watch = next } else { watch = Stopwatch() }
        CountUpStore.update { $0.stopwatch = next }
    }

    var body: some View {
        ZStack {
            stopwatchSky.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer(minLength: 40)
                Text("Stopwatch").skyLabel(12).foregroundStyle(.white.opacity(0.85))
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !watch.isRunning)) { context in
                    VStack(spacing: 6) {
                        Text(Stopwatch.text(watch.elapsed(at: context.date)))
                            .skyDigits(64, weight: .thin).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.4)
                            .accessibilityLabel(Text(Stopwatch.text(watch.elapsed(at: context.date), hundredths: false)))
                        if !watch.splits.isEmpty {
                            Text("Lap \(watch.splits.count + 1) · \(Stopwatch.text(watch.currentLap(at: context.date)))")
                                .font(.subheadline).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button("Lap") { save(watch.lapped()) }
                        .buttonStyle(.glassPill).disabled(!watch.isRunning)
                        .accessibilityIdentifier("stopwatchLap")
                    Button(watch.isRunning ? "Pause" : (watch.elapsed() > 0 ? "Resume" : "Start")) {
                        save(watch.isRunning ? watch.paused() : watch.started())
                    }
                    .buttonStyle(.glassPill)
                    .accessibilityIdentifier("stopwatchStartPause")
                    Button("Reset") { save(nil) }
                        .buttonStyle(.glassPill).disabled(watch.isRunning || watch.elapsed() == 0)
                        .accessibilityIdentifier("stopwatchReset")
                }
                lapList
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }

    private var lapList: some View {
        let lengths = watch.lapLengths
        let fastest = lengths.count >= 3 ? lengths.min() : nil
        let slowest = lengths.count >= 3 ? lengths.max() : nil
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(lengths.enumerated()).reversed(), id: \.offset) { index, length in
                    HStack {
                        Text("Lap \(index + 1)")
                        Spacer()
                        Text(Stopwatch.text(length)).monospacedDigit()
                    }
                    .font(.subheadline)
                    .foregroundStyle(length == fastest ? Color(red: 0.5, green: 0.83, blue: 0.66) : length == slowest ? Color(red: 0.94, green: 0.48, blue: 0.52) : .white)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.15)).frame(height: 1) }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(length == fastest ? Text("Fastest") : length == slowest ? Text("Slowest") : Text(""))
                }
            }
        }
        .frame(maxHeight: 260)
    }
}
