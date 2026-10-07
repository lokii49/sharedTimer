//
//  TimerRunningView.swift
//  sharedTimerMessages
//

import SwiftUI
import UIKit

struct TimerRunningView: View {
    static let storeChange = Notification.Name("SharedTimerMessagesStoreChange")
    @State private var payload: TimerPayload
    let onNewTimer: () -> Void
    let onUpdate: (TimerPayload, String) -> Void
    let onDelete: (TimerPayload) -> Void
    @State private var participantCount: Int?
    @State private var hasBuzzedFinish = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    init(payload: TimerPayload,
         onNewTimer: @escaping () -> Void,
         onUpdate: @escaping (TimerPayload, String) -> Void,
         onDelete: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onNewTimer = onNewTimer
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
            let pending = payload.isPending(at: context.date)

            ZStack {
                Sky.gradient(for: payload, at: context.date)
                    .ignoresSafeArea()

                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Text(payload.label)
                            .skyLabel(12)
                            .foregroundStyle(.white.opacity(0.85))
                        if payload.recurrence != nil { Text("Repeats yearly").font(.caption).foregroundStyle(.white.opacity(0.6)) }
                        if let caption = payload.sequenceCaption {
                            Text(pending ? Sky.pendingSequenceCaption(payload.sequence!) : caption)
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        Text(pending ? Sky.pendingStartText(for: payload.scheduledStartDate!, at: context.date) : TimeFormat.display(remaining))
                            .skyDigits(52, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 20)
                        Text(subtitle(done: done))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(done ? "Timer finished" : "This matches what your friend sees")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 2)
                        if let participantCount, participantCount > 1 {
                            Text("\(participantCount) watching")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    if alarm.isPlaying || vibration.isVibrating {
                        Button("Stop") {
                            alarm.stop()
                            vibration.stop()
                        }
                        .buttonStyle(.glassPill)
                    }

                    if !done && !pending {
                        HStack(spacing: 10) {
                            Button(payload.isPaused ? "Resume" : "Pause") {
                                togglePause()
                            }
                            .buttonStyle(.glassPill)

                            Button("+1:00") {
                                extend(by: 60)
                            }
                            .buttonStyle(.glassPill)
                        }
                    }

                    HStack(spacing: 22) {
                        Button {
                            onNewTimer()
                        } label: {
                            Label("New Timer", systemImage: "plus.circle")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Button {
                            onDelete(payload)
                        } label: {
                            Text("Delete")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }
            }
            // TimelineView localizes invalidation to this closure — a modifier attached
            // outside it (below) only re-evaluates on @State changes, never on the tick
            // that actually crosses zero. `done` is recomputed fresh every tick, so
            // .onChange has to live in here to see the flip.
            .onChange(of: done) { _, isExpired in
                guard isExpired, !hasBuzzedFinish else { return }
                hasBuzzedFinish = true
                if payload.alarmEnabled { alarm.start() }
                // Independent of the alarm path — vibration has its own toggle.
                if payload.vibrationEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vibration.start()
                }
                if payload.sequence != nil || payload.recurrence != nil {
                    payload = payload.advancedSequence(at: context.date)
                    onUpdate(payload, "sequenceAdvanced")
                    hasBuzzedFinish = payload.isExpired
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.storeChange)) { _ in
            if let stored = TimerStore.loadAll().first(where: { $0.id == payload.id }) {
                payload = stored.advancedSequence()
                hasBuzzedFinish = payload.isExpired
                if payload.isPaused { alarm.stop(); vibration.stop() }
            }
        }
        .onAppear {
            payload = payload.advancedSequence()
            hasBuzzedFinish = payload.isExpired
            CloudSyncController.fetchParticipantCount(for: payload) { participantCount = $0 }
        }
        .onDisappear {
            // The Messages extension's own compact/expanded lifecycle can tear this
            // view down while the alarm is still looping (user swipes to another app
            // in the conversation) — nothing else would stop it.
            alarm.stop()
            vibration.stop()
        }
    }

    private func subtitle(done: Bool) -> String {
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

    private func togglePause() {
        payload = payload.isPaused ? payload.resumed() : payload.paused()
        onUpdate(payload, payload.isPaused ? "paused" : "resumed")
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload, "extended")
    }
}
