//
//  TimerAlarmActivityWidget.swift
//  sharedTimerWidget
//
//  Renders the Live Activity / Dynamic Island for an AlarmKit alarm (see
//  AlarmController in the main app). AlarmKit drives one of these per running .timer,
//  replacing the custom per-timer TimerLiveActivityWidget for that kind — the custom
//  one now only runs for .countdown date targets.
//
//  Kept deliberately plain for now: verify the AlarmKit Live Activity renders on device
//  before investing in the sky styling the rest of the app uses.
//

import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

struct TimerAlarmActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TimerAlarmMetadata>.self) { context in
            HStack {
                Label(context.attributes.metadata?.label ?? "Timer", systemImage: "timer")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                alarmCountdownText(context.state)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
            }
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.metadata?.label ?? "Timer", systemImage: "timer")
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    alarmCountdownText(context.state)
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                alarmCountdownText(context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer")
            }
            .keylineTint(TimerKind.timer.accentColor)
        }
    }
}

@ViewBuilder
private func alarmCountdownText(_ state: AlarmPresentationState) -> some View {
    switch state.mode {
    case .countdown(let countdown):
        Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
    case .paused(let paused):
        Text(TimeFormat.remaining(paused.totalCountdownDuration - paused.previouslyElapsedDuration))
    case .alert:
        Text("Time's up")
    @unknown default:
        Text("")
    }
}
