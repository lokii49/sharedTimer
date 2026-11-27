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
import WidgetKit

/// Glyph colour for the round controls. White on the skies (custom Live Activity, home
/// widgets, Dynamic Island); the AlarmKit card sits on the system's Lock Screen
/// background, light in Light Mode, so it uses `Color.primary` — white glyphs on a
/// white 18% circle were near-invisible there.
private struct LiveControlInkKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

extension EnvironmentValues {
    var liveControlInk: Color {
        get { self[LiveControlInkKey.self] }
        set { self[LiveControlInkKey.self] = newValue }
    }
}

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
    @Environment(\.liveControlInk) private var ink
    let timerID: String
    let isPaused: Bool
    let secondary: LiveActivitySecondaryAction
    var size: CGFloat = 44

    var body: some View {
        // A view-only share can't be changed from here (the intents refuse it too).
        if TimerStore.isReadOnly(id: timerID) {
            EmptyView()
        } else {
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            PauseToggle(timerID: timerID, isPaused: isPaused, size: size)

            switch secondary {
            case .stop:
                // ✕ on a repeating countdown skips to its next occurrence and keeps
                // the series (LiveActivityActions.stop) — say so, not "Stop".
                Button(intent: StopTimerIntent(timerID: timerID)) { symbol("xmark") }
                    .accessibilityLabel(repeats ? Text("Skip to next") : Text("Stop"))
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

    private var repeats: Bool {
        TimerStore.loadAll().first { $0.id == timerID }?.recurrence != nil
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(ink.opacity(0.18), in: Circle())
    }
}

/// Home-screen widget controls for one stored payload (Single Timer widget): Repeat
/// once finished, nothing while a sequence is still pending, otherwise the same
/// Pause/Resume + Stop / Next / Cancel pair as the Live Activities.
struct WidgetTimerControls: View {
    let payload: TimerPayload
    /// The timeline entry's date (a precomputed finish entry shows Repeat).
    var date: Date = .now
    var size: CGFloat = 36

    var body: some View {
        let status = TimerWidgetSnapshot(payload: payload, at: date).status
        if status == .scheduled || TimerStore.isReadOnly(id: payload.id) {
            EmptyView()
        } else if status == .finished {
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

/// Pause ⇄ Resume button — see SetTimerPausedIntent for why a plain button and not
/// a toggle.
struct PauseToggle: View {
    @Environment(\.liveControlInk) private var ink
    let timerID: String
    let isPaused: Bool
    var size: CGFloat = 44

    var body: some View {
        Button(intent: SetTimerPausedIntent(timerID: timerID, paused: !isPaused)) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background(ink.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume" : "Pause")
    }
}

// MARK: - Narrow Dynamic Island (iOS 27)

/// The compact trailing slot: `wide` normally, `narrow` when iOS 27 reports the island
/// is limited in width (landscape) — `EnvironmentValues.isDynamicIslandLimitedInWidth`,
/// iOS 27 only, so it is read behind `#available` (deployment target is 26.1).
struct NarrowIslandAware<Wide: View, Narrow: View>: View {
    @ViewBuilder let wide: () -> Wide
    @ViewBuilder let narrow: () -> Narrow

    var body: some View {
        if #available(iOS 27.0, *) {
            LimitedWidthReader(wide: wide, narrow: narrow)
        } else {
            wide()
        }
    }
}

@available(iOS 27.0, *)
private struct LimitedWidthReader<Wide: View, Narrow: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited
    let wide: () -> Wide
    let narrow: () -> Narrow

    var body: some View {
        if limited { narrow() } else { wide() }
    }
}

/// A draining ring for the narrow compact slot (owner's pick, 2026-11-27): live while
/// running (`interval`), frozen at `fraction` left when paused or finished.
struct CompactRing: View {
    var interval: ClosedRange<Date>? = nil
    var fraction: Double? = nil
    let tint: Color

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
            } else if let interval {
                ProgressView(timerInterval: interval, countsDown: true, label: { EmptyView() }, currentValueLabel: { EmptyView() })
            }
        }
        .progressViewStyle(.circular)
        .tint(tint)
        .frame(width: 22, height: 22)
    }
}

