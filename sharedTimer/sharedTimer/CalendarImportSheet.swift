import EventKit
import SwiftUI

/// A copied event, deliberately excluding Calendar identifiers, attendees and notes
/// from the timer's stored/shared payload. Importing never modifies Calendar.
struct CalendarCountdownChoice: Identifiable {
    let id: String
    let title: String
    let date: Date
    let timeZone: TimeZone
    let repeatsYearly: Bool
    let allDay: Bool

    init(event: EKEvent) {
        id = (event.eventIdentifier ?? UUID().uuidString) + "#" + String(event.startDate.timeIntervalSince1970)
        title = (event.title?.isEmpty == false ? event.title : nil) ?? "Countdown"
        timeZone = event.timeZone ?? .current
        allDay = event.isAllDay
        if allDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            date = calendar.startOfDay(for: event.startDate)
        } else { date = event.startDate }
        repeatsYearly = event.calendar?.type == .birthday || (event.recurrenceRules ?? []).contains {
            $0.frequency == .yearly && $0.interval == 1 && $0.recurrenceEnd == nil &&
            ($0.daysOfTheWeek ?? []).isEmpty && ($0.daysOfTheYear ?? []).isEmpty &&
            ($0.weeksOfTheYear ?? []).isEmpty && ($0.setPositions ?? []).isEmpty &&
            ($0.daysOfTheMonth ?? []).count <= 1 && ($0.monthsOfTheYear ?? []).count <= 1
        }
    }
}

@MainActor
protocol CalendarCountdownSource {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date) throws -> [EKEvent]
}

@MainActor
final class EventKitCountdownSource: CalendarCountdownSource {
    private let store = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func events(from start: Date, to end: Date) throws -> [EKEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }
}

@MainActor
@Observable
final class CalendarCountdownImporter {
    private let source: any CalendarCountdownSource
    init(source: (any CalendarCountdownSource)? = nil) { self.source = source ?? EventKitCountdownSource() }
    var choices: [CalendarCountdownChoice] = []
    var isLoading = false
    var message: String?
    var needsSettings = false
    var search = ""
    var visibleChoices: [CalendarCountdownChoice] {
        search.isEmpty ? choices : choices.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    func load() async {
        isLoading = true
        message = nil
        choices = []
        defer { isLoading = false }
        do {
            let status = source.authorizationStatus
            let granted: Bool
            if status == .notDetermined || status == .writeOnly {
                granted = try await source.requestAccess()
            } else { granted = status == .fullAccess }
            guard granted else {
                needsSettings = source.authorizationStatus != .restricted
                message = "Allow Calendar access in Settings to choose an event. You can also enter a date yourself."
                return
            }
            let now = Date()
            let end = Calendar.current.date(byAdding: .year, value: 1, to: now)!
            choices = try source.events(from: now, to: end)
                .filter { $0.startDate > now }.sorted { $0.startDate < $1.startDate }
                .map(CalendarCountdownChoice.init)
            message = choices.isEmpty ? "No upcoming events in the next year. You can enter a date yourself." : nil
            needsSettings = false
        } catch {
            message = "Calendar events couldn’t be loaded. Try again or enter a date yourself."
        }
    }
}

struct CalendarImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importer = CalendarCountdownImporter()
    let onSelect: (CalendarCountdownChoice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose an event in the next year. Its title and start time become your countdown; Calendar stays unchanged.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if importer.isLoading {
                    ProgressView("Loading events…")
                } else if let message = importer.message {
                    Section {
                        Text(message)
                        if importer.needsSettings {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        Button("Try Again") { Task { await importer.load() } }
                    }
                } else {
                    ForEach(importer.visibleChoices) { choice in
                        Button {
                            onSelect(choice)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.title).foregroundStyle(.primary)
                                Text(choice.date.formatted(date: .abbreviated, time: choice.allDay ? .omitted : .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                if choice.repeatsYearly { Text("Repeats yearly").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if importer.visibleChoices.isEmpty { Text("No matching events.").foregroundStyle(.secondary) }
                }
            }
            .searchable(text: $importer.search, prompt: "Find an event")
            .navigationTitle("Import from Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await importer.load() }
        }
    }
}
