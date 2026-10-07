import AppIntents
import SwiftUI
import WidgetKit

struct AccessoryTimerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimerEntry {
        TimerEntry(date: .now, payload: TimerPayload(label: "Pasta", duration: 300))
    }

    func snapshot(for configuration: SelectTimerIntent, in context: Context) async -> TimerEntry {
        let date = Date()
        return TimerEntry(date: date, payload: resolve(configuration, at: date))
    }

    func timeline(for configuration: SelectTimerIntent, in context: Context) async -> Timeline<TimerEntry> {
        let date = Date()
        let snapshots = TimerWidgetSnapshot.timeline(payload: resolve(configuration, at: date), at: date)
        return Timeline(entries: snapshots.map { TimerEntry(date: $0.date, payload: $0.payload) }, policy: .after(TimerWidgetSnapshot.refreshDate(for: snapshots)))
    }

    private func resolve(_ configuration: SelectTimerIntent, at date: Date) -> TimerPayload? {
        TimerWidgetSnapshot.resolve(from: TimerStore.loadAll(), selectedID: configuration.timer?.id, focusID: TimerStore.widgetFocusID, at: date)
    }
}

struct LockScreenTimerEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimerEntry
    var body: some View {
        TimerAccessoryWidgetView(snapshot: TimerWidgetSnapshot(payload: entry.payload, at: entry.date), family: family)
    }
}

struct LockScreenTimerWidget: Widget {
    let kind = "LockScreenTimerWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectTimerIntent.self, provider: AccessoryTimerProvider()) { entry in
            LockScreenTimerEntryView(entry: entry)
        }
        .configurationDisplayName("Lock Screen Timer")
        .description("A timer or countdown with a remaining-time ring. Tap to open its details.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .accessoryCircular) {
    LockScreenTimerWidget()
} timeline: {
    TimerEntry(date: .now, payload: TimerPayload(label: "Pasta", duration: 300))
    TimerEntry(date: .now, payload: TimerPayload(label: "Paused", duration: 300).paused())
}

#Preview(as: .accessoryRectangular) {
    LockScreenTimerWidget()
} timeline: {
    TimerEntry(date: .now, payload: TimerPayload(label: "Pasta", duration: 300))
    TimerEntry(date: .now, payload: TimerPayload(label: "Paused", duration: 300).paused())
}
