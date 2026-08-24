//
//  TimerClipView.swift
//  sharedTimerClip
//

import SwiftUI

/// The App Clip's whole job: one shared timer, full-bleed under its own sky.
struct TimerClipView: View {
    let payload: TimerPayload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAlarmed = false
    @ObservedObject private var alarm = AlarmPlayer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
            let phase = reduceMotion ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 19)

            ZStack {
                LinearGradient(
                    colors: Sky.colors(for: payload, at: context.date),
                    startPoint: UnitPoint(x: 0.15 + 0.1 * phase, y: 0),
                    endPoint: UnitPoint(x: 0.85 - 0.1 * phase, y: 1)
                )
                .ignoresSafeArea()
                .animation(.linear(duration: 1), value: phase)

                VStack {
                    Text(payload.kind == .countdown ? "Shared Countdown" : "Shared Timer")
                        .skyLabel()
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 24)

                    Spacer()

                    VStack(spacing: 10) {
                        Text(payload.label)
                            .skyLabel(13)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(TimeFormat.display(remaining))
                            .skyDigits(64, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 24)
                        Text(subtitle(done: done))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer()

                    Label(
                        done ? "Timer finished" : "Live countdown from a shared timer",
                        systemImage: done ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))

                    if done && alarm.isPlaying {
                        Button("Stop") {
                            alarm.stop()
                        }
                        .buttonStyle(.glassPill)
                        .padding(.top, 10)
                    }

                    Spacer().frame(height: 20)
                }
            }
            // TimelineView localizes invalidation to this closure (see ContentView's
            // TimerDetailView for the same pattern) — `done` is recomputed fresh every
            // tick, so the zero-crossing has to be caught in here.
            .onChange(of: done) { _, isExpired in
                guard isExpired, !hasAlarmed else { return }
                hasAlarmed = true
                alarm.start()
            }
        }
        .onAppear {
            hasAlarmed = payload.isExpired
        }
        .onDisappear {
            alarm.stop()
        }
    }

    private func subtitle(done: Bool) -> String {
        if done {
            return "Finished \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        }
        if payload.isPaused {
            return "Paused"
        }
        if payload.kind == .countdown {
            return TimeFormat.targetDate(payload.endDate)
        }
        return "ends at \(payload.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
