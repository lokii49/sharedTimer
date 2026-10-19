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
            LockScreenTimerView(timerID: context.attributes.timerID, label: liveLabel(context), kind: liveKind(context), state: liveState(context), isFinished: isFinished(context))
                .padding()
                .background(Sky.gradient(endDate: liveState(context).endDate, pausedRemaining: liveState(context).pausedRemaining))
                .activityBackgroundTint(Color.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(liveLabel(context), systemImage: liveKind(context).symbolName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    remainingText(endDate: liveState(context).endDate, pausedRemaining: liveState(context).pausedRemaining)
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Spacer()
                        if !isFinished(context) {
                        LiveActivityControls(
                            timerID: context.attributes.timerID,
                            isPaused: liveState(context).pausedRemaining != nil,
                            secondary: .stop,
                            size: 38
                        )
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: liveKind(context).symbolName)
                    .foregroundStyle(liveKind(context).accentColor)
            } compactTrailing: {
                compactCountdownText(state: liveState(context))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 44)
            } minimal: {
                Image(systemName: liveKind(context).symbolName)
                    .foregroundStyle(liveKind(context).accentColor)
            }
        }
    }
}

/// Lock Screen banner under the timer's sky: small-caps label leading, thin live
/// countdown trailing — the same light-as-time language as everywhere else.
/// Past its end (or marked stale by the system at `staleDate` = endDate): render the
/// finished state instead of a 0:00 that would otherwise sit there for hours, since the
/// app may not be running to end the activity. See LiveActivityController.endFinished.
/// A sequence's stale render moves on to its next quiet phase (`current(at:)`) instead.
private func isFinished(_ context: ActivityViewContext<TimerActivityAttributes>) -> Bool {
    let state = liveState(context)
    let advanced = state.endDate != context.state.endDate
    return state.pausedRemaining == nil && ((context.isStale && !advanced) || state.endDate <= Date())
}

private func liveState(_ context: ActivityViewContext<TimerActivityAttributes>) -> TimerActivityAttributes.ContentState {
    context.state.current(at: Date())
}

/// Label/kind from the content state (they change with each phase and with Edit),
/// falling back to the attributes for an activity started by an older build.
private func liveLabel(_ context: ActivityViewContext<TimerActivityAttributes>) -> String {
    liveState(context).label ?? context.attributes.label
}

private func liveKind(_ context: ActivityViewContext<TimerActivityAttributes>) -> TimerKind {
    liveState(context).kind ?? context.attributes.kind
}

private struct LockScreenTimerView: View {
    let timerID: String
    let label: String
    let kind: TimerKind
    let state: TimerActivityAttributes.ContentState
    let isFinished: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .skyLabel(12)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                remainingText(endDate: state.endDate, pausedRemaining: state.pausedRemaining)
                    .font(.system(size: 30, weight: .light))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 150, alignment: .trailing)
                    .foregroundStyle(.white)
            }
            HStack(alignment: .center) {
                if isFinished {
                    Text("Finished")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else if state.pausedRemaining != nil {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                } else if kind == .countdown {
                    Text(TimeFormat.targetDate(state.endDate))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                // ✕ ends a plain timer; on a sequence (only both-toggles-off phases
                // land on this custom Live Activity) it ends the whole sequence — see
                // LiveActivityActions.stop.
                if !isFinished {
                    LiveActivityControls(
                        timerID: timerID,
                        isPaused: state.pausedRemaining != nil,
                        secondary: .stop
                    )
                }
            }
        }
    }
}

/// Ultra-compact counterpart for the ~44pt Dynamic Island compact slot.
@ViewBuilder
private func compactCountdownText(state: TimerActivityAttributes.ContentState) -> some View {
    if let pausedRemaining = state.pausedRemaining {
        Text(pausedRemaining >= 86400 ? TimeFormat.compactSnapshot(pausedRemaining) : TimeFormat.remaining(pausedRemaining))
    } else if state.endDate.timeIntervalSinceNow >= 86400 {
        Text(TimeFormat.compactSnapshot(state.endDate.timeIntervalSinceNow))
    } else {
        Text(timerInterval: Date.now...max(Date.now, state.endDate), countsDown: true)
    }
}
