//
//  TimerDetailView.swift
//  sharedTimer
//

import SwiftUI
import UIKit

/// Tap-through detail: the timer's sky, full-bleed and slowly swaying, with the time
/// glowing in the middle and frosted controls floating at the bottom.
struct TimerDetailView: View {
    @State private var payload: TimerPayload
    let onUpdate: (TimerPayload, String) -> Void
    /// The tick's own sequence advance — (payload, rearm). See ContentView.apply.
    let onSequenceAdvance: (TimerPayload, Bool) -> Void
    let onDelete: (TimerPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var participantCount: Int?
    @State private var attribution: (name: String, action: String)?
    @State private var hasBuzzedFinish = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    init(payload: TimerPayload, onUpdate: @escaping (TimerPayload, String) -> Void, onSequenceAdvance: @escaping (TimerPayload, Bool) -> Void, onDelete: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onUpdate = onUpdate
        self.onSequenceAdvance = onSequenceAdvance
        self.onDelete = onDelete
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
            let pending = payload.isPending(at: context.date)
            // The sway: gradient anchors drift on a slow sine, one step per second,
            // smoothed by the animation below — the sky never sits perfectly still.
            let phase = reduceMotion ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 19)
            let colors = Sky.colors(for: payload, at: context.date)

            ZStack {
                LinearGradient(
                    colors: colors,
                    startPoint: UnitPoint(x: 0.15 + 0.1 * phase, y: 0),
                    endPoint: UnitPoint(x: 0.85 - 0.1 * phase, y: 1)
                )
                .ignoresSafeArea()
                .animation(.linear(duration: 1), value: phase)
                // Same "not live yet" muting as SkyCard's row treatment.
                .saturation(pending ? 0.35 : 1)
                .brightness(pending ? -0.1 : 0)

                VStack {
                    Spacer()

                    VStack(spacing: 10) {
                        Text(payload.label)
                            .skyLabel(13)
                            .foregroundStyle(.white.opacity(0.85))
                        // "Phase 1 of 2 · Loop 1 of 7" would misread as already running.
                        if pending, let sequence = payload.sequence {
                            Text(Sky.pendingSequenceCaption(sequence))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        } else if let caption = payload.sequenceCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(pending ? (payload.scheduledStartDate.map { Sky.pendingStartText(for: $0, at: context.date) } ?? "") : TimeFormat.display(remaining))
                            .skyDigits(72, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 24)
                        Text(subtitle(done: done, pending: pending))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                        if let statusLine {
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    if pending {
                        // Pause/Extend don't mean anything before the scheduled start
                        // actually begins; Delete (below, unconditional) is Cancel.
                        Button("Start Now") {
                            startEarly()
                        }
                        .buttonStyle(.glassPill)
                    } else if !done {
                        HStack(spacing: 12) {
                            Button("+1:00") {
                                extend(by: 60)
                            }
                            .buttonStyle(.glassPill)

                            Button(payload.isPaused ? "Resume" : "Pause") {
                                togglePause()
                            }
                            .buttonStyle(.glassPill)
                        }
                    } else {
                        HStack(spacing: 12) {
                            if alarm.isPlaying || vibration.isVibrating {
                                Button("Stop") {
                                    alarm.stop()
                                    vibration.stop()
                                    // Same acknowledgment the notification's own "Stop"
                                    // action writes — keeps the two Stop paths consistent.
                                    TimerStore.acknowledgeFinish(id: payload.id)
                                }
                                .buttonStyle(.glassPill)
                            }
                            Button("Repeat") {
                                repeatTimer()
                            }
                            .buttonStyle(.glassPill)
                        }
                    }

                    Button {
                        onDelete(payload)
                        dismiss()
                    } label: {
                        Text("Delete")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            // TimelineView localizes invalidation to this closure — a modifier attached
            // outside it (below) only re-evaluates on @State changes, never on the tick
            // that actually crosses zero. `done` is recomputed fresh every tick, so
            // .onChange has to live in here to see the flip.
            .onChange(of: done) { _, isExpired in
                guard isExpired, !hasBuzzedFinish else { return }
                hasBuzzedFinish = true
                // ContentView's own root-level check also catches this zero-crossing
                // while this screen is pushed, but AlarmPlayer/VibrationPlayer.start()
                // no-op when already running, so calling again here is free — don't
                // rely on the (unverified) assumption that the ancestor TimelineView
                // keeps ticking behind an active NavigationStack push.
                // Only sound/vibrate the in-app loop where the app itself owns the
                // alert (see AlarmController.shouldSoundInAppAlarm/shouldVibrateInApp,
                // and checkForNewlyExpired for why this can't key on alarm-dismissed
                // state).
                if AlarmController.shouldSoundInAppAlarm(for: payload) {
                    alarm.start()
                }
                if AlarmController.shouldVibrateInApp(for: payload) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vibration.start()
                }
                // This view holds its own @State copy, seeded once when pushed, so it
                // needs the same advance-and-reseed ContentView's checkForNewlyExpired
                // does — nothing else refreshes it on a plain tick. Same no-rearm rule
                // as there while AlarmKit owns the alert (see
                // AlarmController.alarmKitOwnsAlert): the next phases are pre-armed, and
                // touching AlarmKit here could race the alert it's presenting.
                if payload.sequence != nil {
                    let advanced = payload.advancedSequence()
                    let rearm = !AlarmController.alarmKitOwnsAlert(for: payload)
                    payload = advanced
                    onSequenceAdvance(advanced, rearm)
                    // Not exhausted -> a new phase just started and can finish again
                    // later; let it re-buzz on that future zero-crossing.
                    hasBuzzedFinish = advanced.isExpired
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // Sequences aren't shareable in v1 — see the row context-menu's identical gate.
            if payload.sequence == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: payload.url()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            hasBuzzedFinish = payload.isExpired
            CloudSyncController.fetchParticipantCount(for: payload) { participantCount = $0 }
            CloudSyncController.fetchAttribution(for: payload) { attribution = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalTimerStoreChange)) { _ in
            // This view holds its own @State copy of payload (seeded once when pushed),
            // so a watch-relayed pause or CloudKit push landing while this exact screen is
            // open would otherwise sit invisible until the user backs out and re-enters —
            // ContentView's own reload (TimerStore.loadAll() into its `timers` array)
            // doesn't touch this already-pushed view's local copy at all.
            guard let fresh = TimerStore.loadAll().first(where: { $0.id == payload.id }) else { return }
            payload = fresh
        }
    }

    private func subtitle(done: Bool, pending: Bool = false) -> String {
        // The big digits above already show the start date/time -- repeating it here
        // ("Starts Sun, 3:00 PM") is the exact duplication SkyCard's redesign fixed.
        // What phase 0 actually is fills this slot instead, same as SkyCard's endText.
        if pending, let sequence = payload.sequence, let phaseText = Sky.pendingFirstPhaseText(sequence) {
            return phaseText
        }
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

    /// Row's own `startEarly` action, mirrored here the same way `togglePause`/`extend`
    /// mirror the row's -- see the row's `startEarly` doc comment for why `repeated()`.
    private func startEarly() {
        payload = payload.repeated()
        onUpdate(payload, "startedEarly")
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload, "extended")
    }

    /// Restart a finished timer from its detail screen — stop any in-app alarm loop,
    /// re-arm the finish handler, and run the standard mutation path (which reschedules
    /// the AlarmKit alarm / notification and Live Activity).
    private func repeatTimer() {
        alarm.stop()
        vibration.stop()
        hasBuzzedFinish = false
        payload = payload.repeated()
        onUpdate(payload, "repeated")
    }

    /// "2 watching" / "Sam paused" — whichever cloud status has resolved so far; nil
    /// (renders nothing) until the on-demand fetches in .onAppear land, and permanently
    /// nil for a purely local timer.
    private var statusLine: String? {
        var parts: [String] = []
        if let participantCount, participantCount > 1 {
            parts.append("\(participantCount) watching")
        }
        if let attribution, attribution.name != DisplayNameStore.name {
            parts.append("\(attribution.name) \(attribution.action)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
