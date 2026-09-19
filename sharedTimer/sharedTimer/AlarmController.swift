//
//  AlarmController.swift
//  sharedTimer
//
//  AlarmKit bridge — MAIN APP TARGET ONLY. This deliberately breaks CLAUDE.md's
//  "duplicate shared logic into every target" rule: AlarmKit is unavailable in app
//  extensions, so sharedTimerClip and sharedTimerMessages cannot schedule an alarm at
//  all and stay on NotificationScheduler's local-notification path. Same "explicit call
//  at every mutation site, never folded into TimerStore" invariant as
//  CloudSyncController / WatchSyncController — and, like those, this file must never be
//  reachable from TimerStore.swift itself (TimerStore is compiled into the Widget).
//
//  Which alert mechanism a timer uses is decided here, by whether EITHER the "Alarm"
//  or "Vibrate" toggle is on (`AlarmController.ownsAlert`) — not by kind. Either toggle
//  on -> AlarmKit: full-screen through the silent switch and Focus, Stop / Repeat
//  panel, survives a force-quit, even locked. `alarmEnabled` picks the loud
//  `alarm.caf` loop; `vibrationEnabled` alone (alarm off) picks `vibration_silent.caf`
//  — a digitally-silent .caf of the same format/duration. AlarmKit's `sound:` param is
//  non-optional with no explicit "no sound" case (checked against the actual
//  AlertConfiguration.AlertSound API: only `.default`/`.named(_:)` exist), so silence
//  is smuggled in as a named asset rather than omitted — resting on the (device-
//  unverified) assumption that AlarmKit's alert vibration isn't decoded from the audio
//  waveform, same as a regular notification's haptic. Both toggles off ->
//  NotificationScheduler: a quiet, standard-sound notification, no AlarmKit at all.
//
//  AlarmKit's own countdown Live Activity replaces the custom per-timer
//  TimerActivityAttributes Live Activity whenever AlarmKit owns the alert — call sites
//  only start the custom one when `!AlarmController.ownsAlert(for:)` (see
//  ContentView.armAlerts).
//

import ActivityKit
import AlarmKit
import CryptoKit
import Foundation
import SwiftUI

enum AlarmController {

    // MARK: - Authorization

    /// Fire-and-forget: ask once at launch so the permission prompt isn't racing the
    /// first schedule call. Safe to call repeatedly.
    static func requestAuthorizationIfNeeded() {
        Task { _ = await ensureAuthorized() }
    }

    /// True when either toggle wants AlarmKit to own this payload's finish. Drives both
    /// `reschedule`'s routing and every call site that skips the custom Live Activity
    /// because AlarmKit runs its own (see ContentView.armAlerts and its mirrors in
    /// AppDelegate / WatchSyncController / TimerIntents).
    static func ownsAlert(for payload: TimerPayload) -> Bool {
        payload.alarmEnabled || payload.vibrationEnabled
    }

    /// True only when the app itself has to sound the finished-alarm loop: the alarm
    /// toggle is on but AlarmKit won't deliver it because permission isn't granted. An
    /// alarm AlarmKit is handling returns false — including one whose alarm the user
    /// already stopped from its panel, so re-opening the app doesn't re-bang. (`alarms`
    /// membership can't tell "never scheduled" from "scheduled then dismissed", so
    /// don't key on it.)
    static func shouldSoundInAppAlarm(for payload: TimerPayload) -> Bool {
        guard payload.alarmEnabled else { return false }
        return AlarmManager.shared.authorizationState != .authorized
    }

    /// True only when the app itself has to vibrate: `vibrationEnabled` is on, and
    /// AlarmKit isn't already the sole owner of this alert. AlarmKit now owns it
    /// whenever authorized and `ownsAlert` is true (which it is here, since
    /// `vibrationEnabled` alone satisfies `ownsAlert`) — it rings full-screen (loud
    /// `alarm.caf` if the alarm toggle is also on, silent `vibration_silent.caf`
    /// otherwise) with its own system vibration, so spinning up `VibrationPlayer` too
    /// would double-buzz while it's ringing, and — the bug this guards against —
    /// re-buzz with a stale "Stop" banner every time the app is reopened after the user
    /// already dismissed AlarmKit's own panel (`checkForNewlyExpired` has no way to see
    /// "already resolved by AlarmKit", only "expired"). Only when AlarmKit is denied /
    /// unavailable does `VibrationPlayer` step in as the fallback loop, same spirit as
    /// `shouldSoundInAppAlarm`'s fallback.
    static func shouldVibrateInApp(for payload: TimerPayload) -> Bool {
        guard payload.vibrationEnabled, !TimerStore.isFinishAcknowledged(id: payload.id) else { return false }
        return AlarmManager.shared.authorizationState != .authorized
    }

    @discardableResult
    private static func ensureAuthorized() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await manager.requestAuthorization()) == .authorized
        @unknown default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Cancels any existing alert (AlarmKit alarm + local notification) for this timer,
    /// then schedules the right one for its current state. Safe from any thread and
    /// safe to call repeatedly — work is serialized per timer id and a call that a
    /// newer reschedule for the same id has overtaken is dropped.
    static func reschedule(for payload: TimerPayload) {
        // Cancel the notification synchronously so a .timer that just switched away
        // from the notification path can't leave a stale one armed.
        NotificationScheduler.cancel(id: payload.id)

        enqueue(payload.id) {
            await cancelAlarm(id: payload.id)

            guard !payload.isPaused, payload.remaining > 0 else { return }

            guard ownsAlert(for: payload) else {
                // Both toggles off: a quiet notification, never AlarmKit.
                NotificationScheduler.scheduleAlert(for: payload)
                return
            }
            if await scheduleAlarm(for: payload) == false {
                // AlarmKit unavailable / denied / at capacity. A local notification is
                // a weaker alarm (one-shot, obeys the silent switch) but beats
                // finishing a timer in silence — same philosophy as
                // NotificationScheduler's own denial fallback.
                NotificationScheduler.scheduleAlert(for: payload)
            }
        }
    }

    /// Full teardown for a deleted timer.
    static func clear(id: String) {
        NotificationScheduler.cancel(id: id)
        enqueue(id) { await cancelAlarm(id: id) }
    }

    /// Folds an AlarmKit-side "Repeat" back into the local model: if the user tapped
    /// Repeat on a fired timer's panel, its alarm is counting down again while our copy
    /// still reads finished. Revive those payloads in place and return their ids; the
    /// caller persists and re-arms **only those** (calling `reschedule` re-aligns the
    /// alarm to the revived endDate, so the approximation here doesn't compound).
    /// Returns [] in the common case — don't touch the other timers.
    static func reconcileRepeat(into timers: inout [TimerPayload]) -> [String] {
        guard let alarms = try? AlarmManager.shared.alarms else { return [] }
        var revivedIDs: [String] = []
        for index in timers.indices where timers[index].isFinished {
            let id = alarmID(for: timers[index].id)
            guard let alarm = alarms.first(where: { $0.id == id }),
                  alarm.state == .countdown else { continue }
            let length = alarm.countdownDuration?.postAlert ?? timers[index].duration
            var revived = timers[index]
            revived.endDate = Date().addingTimeInterval(length)
            revived.pausedRemaining = nil
            timers[index] = revived
            revivedIDs.append(revived.id)
        }
        return revivedIDs
    }

    // MARK: - AlarmKit plumbing

    private static func scheduleAlarm(for payload: TimerPayload) async -> Bool {
        guard await ensureAuthorized() else { return false }

        // AlarmKit derives the Stop control from the alert itself; we only supply the
        // secondary "Repeat" button. `.countdown` behavior makes AlarmKit restart the
        // countdown (for `postAlert` seconds) with no intent of our own.
        let repeatButton = AlarmButton(text: "Repeat", textColor: .white, systemImageName: "repeat")

        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: payload.label),
            secondaryButton: repeatButton,
            secondaryButtonBehavior: .countdown
        )
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: payload.label)
        )
        let presentation = AlarmPresentation(alert: alert, countdown: countdown)

        let attributes = AlarmAttributes<TimerAlarmMetadata>(
            presentation: presentation,
            metadata: TimerAlarmMetadata(timerID: payload.id, label: payload.label, kind: payload.kind),
            tintColor: payload.kind.accentColor
        )

        // preAlert from `remaining` so a resumed / extended timer fires at the right
        // moment; postAlert from `duration` so the panel's Repeat restarts the
        // *original* length, not whatever was left when it finished. The asymmetry is
        // deliberate.
        // Loud alarm.caf when the alarm toggle is on; otherwise (vibration-only)
        // vibration_silent.caf — a digitally-silent .caf of the same format/duration.
        // AlarmKit's `sound:` param is non-optional and has no explicit "no sound"
        // case (checked against the real API — see the file header). Assumption, NOT
        // yet confirmed on-device: the alert's system vibration isn't decoded from the
        // audio waveform, same as a regular notification's haptic firing independent
        // of which sound plays — so a silent asset should still get the full-screen
        // alert + vibration + Stop/Repeat panel with no audible tone. If AlarmKit
        // instead falls back to a default system sound for a silent asset, or refuses
        // to vibrate without real audio, this needs a different approach.
        let config = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>(
            countdownDuration: .init(preAlert: payload.remaining, postAlert: payload.duration),
            attributes: attributes,
            sound: .named(payload.alarmEnabled ? "alarm.caf" : "vibration_silent.caf")
        )

        do {
            _ = try await AlarmManager.shared.schedule(id: alarmID(for: payload.id), configuration: config)
            return true
        } catch {
            print("AlarmController: schedule failed for \(payload.id): \(error)")
            return false
        }
    }

    private static func cancelAlarm(id: String) async {
        do { try AlarmManager.shared.cancel(id: alarmID(for: id)) }
        catch { /* not scheduled, or already fired and dismissed — nothing to do */ }
    }

    /// AlarmKit keys alarms by UUID; TimerPayload.id is a String (a UUID string for
    /// locally created timers, but a shared link can carry any id). Use it directly
    /// when it parses, else derive a stable UUID from its bytes.
    private static func alarmID(for timerID: String) -> UUID {
        if let uuid = UUID(uuidString: timerID) { return uuid }
        let d = Array(SHA256.hash(data: Data(timerID.utf8)))  // 32 bytes
        let bytes: uuid_t = (d[0], d[1], d[2], d[3], d[4], d[5],
                             (d[6] & 0x0F) | 0x50, d[7],
                             (d[8] & 0x3F) | 0x80, d[9],
                             d[10], d[11], d[12], d[13], d[14], d[15])
        return UUID(uuid: bytes)
    }

    // MARK: - Per-id serialization

    private static func enqueue(_ id: String, _ work: @escaping @Sendable () async -> Void) {
        Task { await Serializer.shared.run(id, work) }
    }

    private actor Serializer {
        static let shared = Serializer()
        private var tail: [String: Task<Void, Never>] = [:]

        func run(_ id: String, _ work: @escaping @Sendable () async -> Void) {
            let previous = tail[id]
            let task = Task {
                await previous?.value
                await work()
            }
            tail[id] = task
            Task { [weak self] in
                await task.value
                await self?.clear(id, ifTail: task)
            }
        }

        private func clear(_ id: String, ifTail task: Task<Void, Never>) {
            if tail[id] == task { tail[id] = nil }
        }
    }
}
