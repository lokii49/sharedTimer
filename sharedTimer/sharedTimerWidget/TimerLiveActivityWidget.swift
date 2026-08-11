//
//  TimerLiveActivityWidget.swift
//  sharedTimerWidget
//

import ActivityKit
import WidgetKit
import SwiftUI

struct TimerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenTimerView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.label, systemImage: symbolName(for: context.attributes.kind))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(state: context.state)
                        .monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: symbolName(for: context.attributes.kind))
            } compactTrailing: {
                compactCountdownText(state: context.state)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: symbolName(for: context.attributes.kind))
            }
        }
    }
}

private struct LockScreenTimerView: View {
    let attributes: TimerActivityAttributes
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(attributes.label, systemImage: symbolName(for: attributes.kind))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                countdownText(state: state)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            if attributes.kind == .countdown {
                Text("→ \(TimeFormat.targetDate(state.endDate))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private func symbolName(for kind: TimerKind) -> String {
    kind == .countdown ? "calendar" : "timer"
}

/// Full remaining time, day-aware ("3d 04:12:09"), for lock screen and the expanded island.
@ViewBuilder
private func countdownText(state: TimerActivityAttributes.ContentState) -> some View {
    if let pausedRemaining = state.pausedRemaining {
        Text(TimeFormat.remaining(pausedRemaining))
    } else if state.endDate.timeIntervalSinceNow >= 86400 {
        Text(TimeFormat.remaining(state.endDate.timeIntervalSinceNow))
    } else {
        Text(timerInterval: Date.now...max(Date.now, state.endDate), countsDown: true)
    }
}

/// Compact "3d" or live HH:MM:SS for the ~44pt compact Dynamic Island slot.
@ViewBuilder
private func compactCountdownText(state: TimerActivityAttributes.ContentState) -> some View {
    if let pausedRemaining = state.pausedRemaining {
        Text(pausedRemaining >= 86400 ? TimeFormat.compactDays(pausedRemaining) : TimeFormat.remaining(pausedRemaining))
    } else if state.endDate.timeIntervalSinceNow >= 86400 {
        Text(TimeFormat.compactDays(state.endDate.timeIntervalSinceNow))
    } else {
        Text(timerInterval: Date.now...max(Date.now, state.endDate), countsDown: true)
    }
}
