//
//  TimerAlarmActivityWidget.swift
//  sharedTimerWidget
//
//  Renders the Live Activity / Dynamic Island for an AlarmKit alarm (see
//  AlarmController in the main app). AlarmKit drives one of these per running timer or
//  countdown whose "Alarm" toggle is on, replacing the custom per-timer
//  TimerLiveActivityWidget — the custom one now only runs for the alarm-off case.
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
            let kind = context.attributes.metadata?.kind ?? .timer
            // Stacked, not side-by-side with the countdown — an HStack + Spacer left
            // the label only the leftover width after the countdown text, truncating
            // any label longer than a few characters (see the "Alarm only cou…" report).
            // Full width to the label, wrapping up to 2 lines, fixes that.
            VStack(alignment: .leading, spacing: 4) {
                Label(context.attributes.metadata?.label ?? "Timer", systemImage: kind.symbolName)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                alarmCountdownText(context.state)
                    .font(.title2.weight(.medium))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let kind = context.attributes.metadata?.kind ?? .timer
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.metadata?.label ?? "Timer", systemImage: kind.symbolName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    alarmCountdownText(context.state)
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(kind.accentColor)
            } compactTrailing: {
                alarmCountdownText(context.state)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            } minimal: {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(kind.accentColor)
            }
            .keylineTint(kind.accentColor)
        }
    }
}

@ViewBuilder
private func alarmCountdownText(_ state: AlarmPresentationState) -> some View {
    switch state.mode {
    case .countdown(let countdown):
        // Always the self-ticking system view, at any duration: AlarmKit — not this
        // app — owns this Live Activity's update cadence, so a static formatted string
        // here (e.g. a day-count snapshot) would freeze until AlarmKit next happens to
        // push a state update, unlike the sibling TimerLiveActivityWidget's equivalent,
        // which the main app's own LiveActivityController keeps refreshing. If a
        // far-future countdown still doesn't render at this width, the fix is a wider
        // frame on the caller, not a switch away from `Text(timerInterval:)`.
        Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
    case .paused(let paused):
        Text(TimeFormat.remaining(paused.totalCountdownDuration - paused.previouslyElapsedDuration))
    case .alert:
        Text("Time's up")
    @unknown default:
        Text("")
    }
}
