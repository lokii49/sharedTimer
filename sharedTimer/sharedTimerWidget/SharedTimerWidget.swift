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
        let refreshDate = payload?.endDate ?? Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func nearestActive() -> TimerPayload? {
        TimerStore.loadAll()
            .filter { !$0.isExpired && !$0.isPaused }
            .sorted { $0.endDate < $1.endDate }
            .first
    }
}

struct SharedTimerWidgetView: View {
    let entry: TimerEntry

    var body: some View {
        if let payload = entry.payload {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(timerInterval: Date.now...max(Date.now, payload.endDate), countsDown: true)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        } else {
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
}

struct SharedTimerWidget: Widget {
    let kind = "SharedTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimerTimelineProvider()) { entry in
            SharedTimerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Shared Timer")
        .description("Shows your nearest active shared timer.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
