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
                    Label(context.attributes.label, systemImage: "timer")
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(state: context.state)
                        .monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                countdownText(state: context.state)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}

private struct LockScreenTimerView: View {
    let attributes: TimerActivityAttributes
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        HStack {
            Label(attributes.label, systemImage: "timer")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            countdownText(state: state)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}

@ViewBuilder
private func countdownText(state: TimerActivityAttributes.ContentState) -> some View {
    if let pausedRemaining = state.pausedRemaining {
        Text(clockString(pausedRemaining))
    } else {
        Text(timerInterval: Date.now...max(Date.now, state.endDate), countsDown: true)
    }
}

private func clockString(_ interval: TimeInterval) -> String {
    let t = max(0, Int(interval))
    let h = t / 3600
    let m = (t % 3600) / 60
    let s = t % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
