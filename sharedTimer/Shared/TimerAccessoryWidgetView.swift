import SwiftUI
import WidgetKit

/// Monochrome accessory layouts; the system supplies the Lock Screen's tint.
struct TimerAccessoryWidgetView: View {
    let snapshot: TimerWidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                HStack(spacing: 8) {
                    ring(showTime: false).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.payload?.label ?? "No Timers")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if snapshot.status == .scheduled {
                                Text("Starts").font(.caption2)
                            }
                            timeText
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if snapshot.status == .paused {
                                Text("Paused").font(.caption2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ring(showTime: true)
            }
        }
        .foregroundStyle(.primary)
        .containerBackground(.clear, for: .widget)
        .widgetURL(snapshot.payload.map { TimerAppLink.url(for: $0.id) })
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.payload?.label ?? "No timers")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(snapshot.payload == nil ? "Open Timer" : "Open timer details")
    }

    private func ring(showTime: Bool) -> some View {
        ZStack {
            Group {
                if let interval = snapshot.timerInterval {
                    // Built-in circular style is a capacity gauge in WidgetKit.
                    // The timer interval lets the system animate it between entries.
                    ProgressView(timerInterval: interval, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                } else {
                    Gauge(value: snapshot.progress, in: 0...1) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                }
            }
            // Accessory gauges keep their intrinsic size; scale their artwork before
            // assigning the rectangular slot, otherwise the ring overlaps the text.
            .frame(width: 58, height: 58)
            .scaleEffect(showTime ? 1 : 38.0 / 58.0)
            .frame(width: showTime ? 58 : 38, height: showTime ? 58 : 38)
            .accessibilityHidden(true)
            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: showTime ? 10 : 14, weight: .semibold))
                if showTime {
                    timeText
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .padding(showTime ? 10 : 6)
        }
    }

    @ViewBuilder private var timeText: some View {
        switch snapshot.status {
        case .empty: Text("—")
        case .finished: Text("Done")
        case .scheduled:
            if let start = snapshot.payload?.scheduledStartDate {
                Text(start, style: .time)
            }
        case .paused:
            Text(family == .accessoryCircular && snapshot.remaining >= 86400
                 ? TimeFormat.compactSnapshot(snapshot.remaining, at: snapshot.date)
                 : TimeFormat.display(snapshot.remaining, at: snapshot.date))
        case .running:
            if let end = snapshot.payload?.endDate {
                if snapshot.remaining < 86400 {
                    Text(timerInterval: snapshot.date...end, countsDown: true)
                } else {
                    Text(family == .accessoryCircular
                         ? TimeFormat.compactSnapshot(snapshot.remaining, at: snapshot.date)
                         : TimeFormat.snapshot(snapshot.remaining, at: snapshot.date))
                }
            }
        }
    }

    private var symbol: String {
        switch snapshot.status {
        case .empty: return "timer"
        case .finished: return "checkmark"
        case .scheduled: return "calendar.badge.clock"
        case .paused: return "pause.fill"
        case .running: return snapshot.payload?.kind == .countdown ? "calendar" : "timer"
        }
    }

    private var accessibilityValue: String {
        switch snapshot.status {
        case .empty: return "Add a timer in the app"
        case .finished: return "Finished"
        case .paused: return "Paused, \(TimeFormat.display(snapshot.remaining, at: snapshot.date)) remaining"
        case .scheduled:
            return "Scheduled to start \(snapshot.payload!.scheduledStartDate!.formatted(date: .abbreviated, time: .shortened))"
        case .running:
            return "Running, ends \(snapshot.payload!.endDate.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}
