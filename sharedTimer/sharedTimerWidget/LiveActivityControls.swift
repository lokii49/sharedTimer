//
//  LiveActivityControls.swift
//  sharedTimerWidget
//
//  The Pause/Resume + Stop (or Next/Cancel for a sequence) button pair shown on both
//  Live Activities — AlarmKit's (TimerAlarmActivityWidget) and the custom one
//  (TimerLiveActivityWidget) — on the Lock Screen and in the expanded Dynamic Island.
//  Same two-button layout as the Clock app's timer. Each button runs a
//  `LiveActivityIntent` from Shared/LiveActivityIntents.swift, which the system
//  executes in the app's process (see that file's header).
//

import AppIntents
import SwiftUI

/// What the second button does.
enum LiveActivitySecondaryAction {
    /// Plain timer/countdown: end it now (StopTimerIntent).
    case stop
    /// Sequence phase with more to go: start the next one (AdvanceSequenceIntent).
    case next(phaseIndex: Int)
    /// Final sequence phase: end the sequence (EndSequenceIntent).
    case cancelSequence
}

struct LiveActivityControls: View {
    let timerID: String
    let isPaused: Bool
    let secondary: LiveActivitySecondaryAction
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            PauseToggle(timerID: timerID, isPaused: isPaused, size: size)

            switch secondary {
            case .stop:
                Button(intent: StopTimerIntent(timerID: timerID)) { symbol("xmark") }
                    .accessibilityLabel("Stop")
            case .next(let phaseIndex):
                Button(intent: AdvanceSequenceIntent(timerID: timerID, phaseIndex: phaseIndex)) { symbol("forward.end.fill") }
                    .accessibilityLabel("Next phase")
            case .cancelSequence:
                Button(intent: EndSequenceIntent(timerID: timerID)) { symbol("xmark") }
                    .accessibilityLabel("End sequence")
            }
        }
        .buttonStyle(.plain)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.white.opacity(0.18), in: Circle())
    }
}

/// Home-screen widget controls for one stored payload (Single Timer widget): Repeat
/// once finished, nothing while a sequence is still pending, otherwise the same
/// Pause/Resume + Stop / Next / Cancel pair as the Live Activities.
struct WidgetTimerControls: View {
    let payload: TimerPayload
    var size: CGFloat = 36

    var body: some View {
        if payload.isPending() {
            EmptyView()
        } else if payload.isFinished {
            Button(intent: RepeatTimerIntent(timerID: payload.id)) {
                Label("Repeat", systemImage: "arrow.clockwise")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, size * 0.35)
                    .frame(height: size)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            LiveActivityControls(
                timerID: payload.id,
                isPaused: payload.isPaused,
                secondary: secondary,
                size: size
            )
        }
    }

    private var secondary: LiveActivitySecondaryAction {
        guard let sequence = payload.sequence, let index = payload.sequenceGlobalIndex else { return .stop }
        return index == sequence.phases.count * sequence.loopCount - 1 ? .cancelSequence : .next(phaseIndex: index)
    }
}

/// Pause ⇄ Resume as a toggle (isOn = paused) — see SetTimerPausedIntent for why a
/// toggle and not a button: WidgetKit redraws it the instant it's tapped.
struct PauseToggle: View {
    let timerID: String
    let isPaused: Bool
    var size: CGFloat = 44

    var body: some View {
        Toggle(isOn: isPaused, intent: SetTimerPausedIntent(timerID: timerID)) {
            Text(isPaused ? "Resume" : "Pause")
        }
        .toggleStyle(PauseToggleStyle(size: size))
    }
}

private struct PauseToggleStyle: ToggleStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        // A custom style has to route the tap through `configuration.isOn` itself —
        // drawn without this Button, the toggle rendered but taps did nothing (found
        // on device). In a widget, toggling the binding is what fires the intent;
        // `configuration.isOn` is the optimistic state, already flipped on tap.
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "play.fill" : "pause.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.white.opacity(0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.isOn ? "Resume" : "Pause")
    }
}

