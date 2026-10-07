//
//  TimerClipView.swift
//  sharedTimerClip
//

import SwiftUI
import UIKit

/// The App Clip's whole job: one shared timer, full-bleed under its own sky.
struct TimerClipView: View {
    let payload: TimerPayload
    @State private var current: TimerPayload?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAlarmed = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let payload = (current ?? self.payload).advancedSequence(at: context.date)
            let remaining = payload.remaining
            let done = payload.isExpired
            let pending = payload.isPending(at: context.date)
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
                        if payload.recurrence != nil { Text("Repeats yearly").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                        if let caption = payload.sequenceCaption {
                            Text(pending ? Sky.pendingSequenceCaption(payload.sequence!) : caption)
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        Text(pending ? Sky.pendingStartText(for: payload.scheduledStartDate!, at: context.date) : TimeFormat.display(remaining))
                            .skyDigits(64, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 24)
                        Text(subtitle(payload: payload, done: done))
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

                    if alarm.isPlaying || vibration.isVibrating {
                        Button("Stop") {
                            alarm.stop()
                            vibration.stop()
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
            .onChange(of: payload.sequenceGlobalIndex) { _, _ in
                let before = current ?? self.payload
                if !hasAlarmed && !before.isPending() {
                    if before.alarmEnabled { alarm.start() }
                    if before.vibrationEnabled { vibration.start() }
                }
                current = payload
                TimerStore.save(payload)
                if !TimerStore.isAlarmKitArmed(id: payload.id) { NotificationScheduler.scheduleAlert(for: payload) }
                hasAlarmed = done
            }
            .onChange(of: payload.endDate) { _, _ in
                guard payload.recurrence != nil else { return }
                let before = current ?? self.payload
                if before.alarmEnabled { alarm.start() }
                if before.vibrationEnabled { vibration.start() }
                current = payload
                TimerStore.save(payload)
                if !TimerStore.isAlarmKitArmed(id: payload.id) { NotificationScheduler.scheduleAlert(for: payload) }
            }
            .onChange(of: done) { _, isExpired in
                guard payload.sequence == nil, isExpired, !hasAlarmed else { return }
                hasAlarmed = true
                if payload.alarmEnabled { alarm.start() }
                if payload.vibrationEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vibration.start()
                }
            }
        }
        .onAppear {
            current = payload.advancedSequence()
            hasAlarmed = current!.isExpired
        }
        .onDisappear {
            alarm.stop()
            vibration.stop()
        }
    }

    private func subtitle(payload: TimerPayload, done: Bool) -> String {
        if payload.isPending(), let sequence = payload.sequence { return Sky.pendingFirstPhaseText(sequence) ?? "Scheduled" }
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
