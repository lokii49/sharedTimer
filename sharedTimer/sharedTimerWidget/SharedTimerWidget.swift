//
//  SharedTimerWidget.swift
//  sharedTimerWidget
//

import WidgetKit
import SwiftUI
import AppIntents

struct TimerEntry: TimelineEntry {
    let date: Date
    let payload: TimerPayload?
}

// MARK: - Live remaining text

/// The countdown value for widget surfaces. Under a day it's a system-rendered
/// `Text(timerInterval:)`, which WidgetKit ticks every second for free — a widget
/// snapshot can't re-render itself, so any hand-formatted string would freeze between
/// timeline refreshes. Coarser values render static, honest strings ("3d 4h", "1mo 8d")
/// rather than fake ticking seconds; a paused value is frozen anyway.
///
/// `Text(timerInterval:)` claims all the width it's offered, so trailing-aligned uses
/// must cap it with an explicit frame.
@ViewBuilder
func remainingText(endDate: Date, pausedRemaining: TimeInterval?) -> some View {
    let remaining = max(0, endDate.timeIntervalSinceNow)
    if pausedRemaining == nil && remaining > 0 && remaining < 86400 {
        Text(timerInterval: Date.now...max(Date.now, endDate), countsDown: true)
    } else {
        Text(staticRemainingString(endDate: endDate, pausedRemaining: pausedRemaining))
    }
}

func staticRemainingString(endDate: Date, pausedRemaining: TimeInterval?) -> String {
    if let pausedRemaining {
        return TimeFormat.display(pausedRemaining)
    }
    let remaining = max(0, endDate.timeIntervalSinceNow)
    if remaining <= 0 {
        return "00:00"
    }
    if remaining >= TimeFormat.calendarThreshold {
        return TimeFormat.calendarBreakdown(remaining)
    }
    return TimeFormat.daysHours(remaining)
}

/// Shared refresh policy: the live text ticks by itself, so the timeline only wakes for
/// state changes — coarse day-range strings rolling over, and expiry.
func nextRefresh(for payload: TimerPayload?) -> Date {
    guard let payload, !payload.isExpired, !payload.isPaused else {
        return Date().addingTimeInterval(15 * 60)
    }
    let remaining = payload.remaining
    if remaining > TimeFormat.calendarThreshold {
        return Date().addingTimeInterval(min(remaining - TimeFormat.calendarThreshold, 6 * 3600))
    }
    if remaining > 86400 {
        // "3d 4h" only changes on the hour.
        return Date().addingTimeInterval(3600)
    }
    return Date().addingTimeInterval(max(remaining, 1))
}

// MARK: - Configurable single-timer widget

/// Lightweight `AppEntity` wrapper so the widget-configuration UI can list timers by name;
/// only carries what the picker needs, not the full `TimerPayload`.
struct TimerChoice: AppEntity {
    let id: String
    let label: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static var defaultQuery = TimerChoiceQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)")
    }
}

struct TimerChoiceQuery: EntityQuery {
    func entities(for identifiers: [TimerChoice.ID]) async throws -> [TimerChoice] {
        let all = TimerStore.loadAll()
        return identifiers.compactMap { id in
            all.first { $0.id == id }.map { TimerChoice(id: $0.id, label: $0.label) }
        }
    }

    func suggestedEntities() async throws -> [TimerChoice] {
        TimerStore.loadAll()
            .filter { !$0.isExpired }
            .sorted { $0.endDate < $1.endDate }
            .map { TimerChoice(id: $0.id, label: $0.label) }
    }
}

struct SelectTimerIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Timer"
    static var description = IntentDescription("Pick which timer or countdown this widget shows.")

    @Parameter(title: "Timer")
    var timer: TimerChoice?
}

struct ConfigurableTimerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimerEntry {
        TimerEntry(date: .now, payload: TimerPayload(label: "Coffee break", duration: 300))
    }

    func snapshot(for configuration: SelectTimerIntent, in context: Context) async -> TimerEntry {
        TimerEntry(date: .now, payload: resolve(configuration))
    }

    func timeline(for configuration: SelectTimerIntent, in context: Context) async -> Timeline<TimerEntry> {
        let payload = resolve(configuration)
        return Timeline(entries: [TimerEntry(date: .now, payload: payload)], policy: .after(nextRefresh(for: payload)))
    }

    /// A configured timer is shown as-is (even paused or just-finished) — the user picked
    /// it specifically. Only fall back to "nearest active" when unconfigured or deleted.
    private func resolve(_ configuration: SelectTimerIntent) -> TimerPayload? {
        let all = TimerStore.loadAll()
        if let id = configuration.timer?.id, let match = all.first(where: { $0.id == id }) {
            return match
        }
        return all.filter { !$0.isExpired && !$0.isPaused }.sorted { $0.endDate < $1.endDate }.first
    }
}

struct BigCountdownWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let payload: TimerPayload?

    var body: some View {
        Group {
            if let payload {
                content(for: payload)
            } else {
                emptyView
            }
        }
        .containerBackground(for: .widget) {
            // The widget IS the timer's sky, edge to edge. The sky is fixed artwork — all
            // text on it is white, so nothing here needs to adapt to Light/Dark Mode.
            if let payload {
                Sky.gradient(for: payload)
            } else {
                Sky.room
            }
        }
    }

    private var isSmall: Bool { family == .systemSmall }

    private func content(for payload: TimerPayload) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(payload.label)
                    .skyLabel(isSmall ? 10 : 11)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if payload.isPaused {
                    Text("Paused").skyLabel(isSmall ? 9 : 10)
                } else if payload.isExpired {
                    Text("Time's up").skyLabel(isSmall ? 9 : 10)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            Spacer(minLength: 0)

            remainingText(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining)
                .font(.system(size: isSmall ? 34 : 46, weight: .regular))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.white)

            Text(footerText(for: payload))
                .skyLabel(isSmall ? 9.5 : 10.5)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(isSmall ? 2 : 4)
    }

    private func footerText(for payload: TimerPayload) -> String {
        if payload.isPaused {
            return "held"
        }
        if payload.isExpired {
            return "finished \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        }
        if payload.kind == .countdown {
            return TimeFormat.targetDate(payload.endDate)
        }
        return "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(Sky.roomInk)
            Text("No Timers")
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SharedTimerCountdownWidget: Widget {
    let kind = "SharedTimerCountdownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectTimerIntent.self, provider: ConfigurableTimerProvider()) { entry in
            BigCountdownWidgetView(payload: entry.payload)
        }
        .configurationDisplayName("Single Timer")
        .description("Pick one timer or countdown to show big, on its own.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - All-timers list widget

struct TimerListEntry: TimelineEntry {
    let date: Date
    let payloads: [TimerPayload]
}

struct TimerListProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimerListEntry {
        TimerListEntry(date: .now, payloads: [TimerPayload(label: "Coffee break", duration: 300)])
    }

    func getSnapshot(in context: Context, completion: @escaping (TimerListEntry) -> Void) {
        completion(TimerListEntry(date: .now, payloads: activeSorted()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimerListEntry>) -> Void) {
        let payloads = activeSorted()
        completion(Timeline(entries: [TimerListEntry(date: .now, payloads: payloads)], policy: .after(nextRefresh(for: payloads.first))))
    }

    private func activeSorted() -> [TimerPayload] {
        TimerStore.loadAll()
            .filter { !$0.isExpired }
            .sorted { $0.endDate < $1.endDate }
    }
}

struct TimerListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimerListEntry

    private var maxRows: Int { family == .systemLarge ? 5 : 2 }

    var body: some View {
        Group {
            if entry.payloads.isEmpty {
                emptyView
            } else {
                VStack(spacing: 7) {
                    let shown = Array(entry.payloads.prefix(maxRows))
                    ForEach(shown) { payload in
                        // Fixed row height, stack pinned to the top — with a single timer
                        // the row must not stretch and drift to the vertical center.
                        row(payload)
                            .frame(height: 54)
                    }
                    if entry.payloads.count > maxRows {
                        Text("\(entry.payloads.count - maxRows) more…")
                            .font(.caption2)
                            .foregroundStyle(Sky.roomInk)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // The dark room, fixed — each row hangs in it as its own small sky.
        .containerBackground(Sky.room, for: .widget)
    }

    /// A miniature sky card: label and end info on the left, live remaining time on the
    /// right. The live text claims all offered width, so it's capped.
    private func row(_ payload: TimerPayload) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.label)
                    .skyLabel(10)
                    .lineLimit(1)
                Text(payload.isPaused
                     ? "held"
                     : (payload.kind == .countdown
                        ? TimeFormat.targetDate(payload.endDate)
                        : "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"))
                    .skyLabel(9.5)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.9))

            Spacer(minLength: 6)

            remainingText(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining)
                .font(.system(size: 22, weight: .medium))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
                .frame(maxWidth: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Sky.gradient(for: payload))
        )
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(Sky.roomInk)
            Text("No Timers")
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The default widget — same `kind` as before, so it updates in place on home screens
/// that already have it placed rather than requiring a re-add.
struct SharedTimerWidget: Widget {
    let kind = "SharedTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimerListProvider()) { entry in
            TimerListWidgetView(entry: entry)
        }
        .configurationDisplayName("All Timers")
        .description("Lists every active timer and countdown, soonest first.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
