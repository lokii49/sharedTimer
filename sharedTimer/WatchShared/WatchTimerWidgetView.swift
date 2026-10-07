import SwiftUI
import WidgetKit

struct WatchTimerWidgetView: View {
    let snapshot: WatchTimerSnapshot
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    init(snapshot: WatchTimerSnapshot, family: WidgetFamily? = nil) {
        self.snapshot = snapshot
        self.familyOverride = family
    }

    private var symbol: String {
        snapshot.timer == nil ? "timer" : (snapshot.remaining <= 0 ? "checkmark" : (snapshot.timer!.isPaused ? "pause.fill" : "timer"))
    }
    @ViewBuilder private var time: some View {
        if snapshot.isRunning, snapshot.remaining < 86400, let timer = snapshot.timer {
            Text(timerInterval: snapshot.date...timer.endDate, countsDown: true).monospacedDigit()
        } else if snapshot.remaining > 0 {
            Text(snapshot.remaining >= 86400
                 ? (family == .accessoryCircular ? TimeFormat.compactSnapshot(snapshot.remaining, at: snapshot.date) : TimeFormat.snapshot(snapshot.remaining, at: snapshot.date))
                 : TimeFormat.display(snapshot.remaining, at: snapshot.date)).monospacedDigit()
        } else {
            Text(snapshot.timer == nil ? "—" : "Done")
        }
    }
    private func ring(showTime: Bool) -> some View {
        ZStack {
            Group {
                if snapshot.isRunning, let timer = snapshot.timer {
                    ProgressView(timerInterval: timer.endDate.addingTimeInterval(-max(timer.duration, snapshot.remaining))...timer.endDate, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.circular)
                } else {
                    // A frozen ring uses SwiftUI geometry, so paused and empty states
                    // also render consistently outside the WidgetKit host.
                    ZStack {
                        Circle().stroke(.primary.opacity(0.2), lineWidth: 5)
                        Circle().trim(from: 0, to: snapshot.progress)
                            .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.padding(3)
                }
            }.frame(width: 58, height: 58)
                .scaleEffect(showTime ? 1 : 40.0 / 58)
                .frame(width: showTime ? 58 : 40, height: showTime ? 58 : 40)
                .accessibilityHidden(true)
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: showTime ? 10 : 16, weight: .semibold))
                if showTime {
                    time.font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.4)
                }
            }.padding(showTime ? 10 : 6)
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                ViewThatFits {
                    HStack { Image(systemName: symbol); Text(snapshot.timer?.label ?? "Shared Timer"); time }
                    HStack { Image(systemName: symbol); time }
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    ring(showTime: false).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.timer?.label ?? "Shared Timer").font(.headline).lineLimit(1)
                        time.font(.title3).lineLimit(1).minimumScaleFactor(0.5)
                        Text(snapshot.timer == nil ? "Sync timers from iPhone" : snapshot.status)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            default: ring(showTime: true)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(snapshot.timer.flatMap { WatchTimerLink.url(id: $0.id) })
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.timer?.label ?? "Shared Timer"), \(snapshot.status), \(TimeFormat.display(snapshot.remaining, at: snapshot.date))")
    }
}

