//
//  SharedTimerWidget.swift
//  sharedTimerWidget
//

import WidgetKit
import SwiftUI

struct TimerEntry: TimelineEntry {
    let date: Date
    let payload: TimerPayload?
}

struct TimerTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimerEntry {
        TimerEntry(date: .now, payload: TimerPayload(label: "Coffee break", duration: 300))
    }

    func getSnapshot(in context: Context, completion: @escaping (TimerEntry) -> Void) {
        completion(TimerEntry(date: .now, payload: nearestActive()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimerEntry>) -> Void) {
        let payload = nearestActive()
        let entry = TimerEntry(date: .now, payload: payload)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh(for: payload))))
    }

    private func nearestActive() -> TimerPayload? {
        TimerStore.loadAll()
            .filter { !$0.isExpired && !$0.isPaused }
            .sorted { $0.endDate < $1.endDate }
            .first
    }

    /// Day-scale values only need to refresh roughly hourly (or right when they
    /// drop under a day, so the display switches to the live HH:MM:SS form).
    /// Sub-day values tick live via `Text(timerInterval:)`, so we just need a
    /// reload once they finish.
    private func nextRefresh(for payload: TimerPayload?) -> Date {
        guard let payload else {
            return Date().addingTimeInterval(15 * 60)
        }
        let remaining = payload.remaining
        if remaining > 86400 {
            return Date().addingTimeInterval(min(remaining - 86400, 3600))
        }
        return payload.endDate
    }
}

struct SharedTimerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TimerEntry

    var body: some View {
        if let payload = entry.payload {
            switch family {
            case .systemMedium:
                mediumView(payload)
            default:
                smallView(payload)
            }
        } else {
            emptyView
        }
    }

    private func smallView(_ payload: TimerPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(payload.label, systemImage: payload.kind == .countdown ? "calendar" : "timer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            countdownValue(for: payload)
                .font(.title2.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediumView(_ payload: TimerPayload) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Label(payload.label, systemImage: payload.kind == .countdown ? "calendar" : "timer")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(payload.kind == .countdown
                     ? "→ \(TimeFormat.targetDate(payload.endDate))"
                     : "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            countdownValue(for: payload)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func countdownValue(for payload: TimerPayload) -> some View {
        if payload.remaining >= 86400 {
            Text(TimeFormat.compactDays(payload.remaining))
        } else {
            Text(timerInterval: Date.now...max(Date.now, payload.endDate), countsDown: true)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No active timers")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SharedTimerWidget: Widget {
    let kind = "SharedTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimerTimelineProvider()) { entry in
            SharedTimerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Shared Timer")
        .description("Shows your nearest active timer or countdown.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
