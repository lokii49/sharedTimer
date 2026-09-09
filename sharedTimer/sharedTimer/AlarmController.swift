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
//  Which alert mechanism a timer uses is decided here, by kind:
//    - .timer     -> AlarmKit: rings through the silent switch and Focus, shows a
//                    full-screen Stop / Repeat panel, and survives a force-quit.
//    - .countdown -> NotificationScheduler: a months-out date target ("days until
//                    vacation") wants a gentle notification, not a ringing alarm.
//
//  AlarmKit's own countdown Live Activity replaces the custom per-timer
//  TimerActivityAttributes Live Activity for .timer — call sites only start the custom
//  one for .countdown now (see ContentView).
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

    /// True only when the app itself has to sound the finished-alarm loop: a
    /// `.countdown` (never AlarmKit), or a `.timer` whose alarm AlarmKit won't deliver
    /// because permission isn't granted. A `.timer` AlarmKit is handling returns
    /// false — including one whose alarm the user already stopped from its panel, so
    /// re-opening the app doesn't re-bang. (`alarms` membership can't tell "never
    /// scheduled" from "scheduled then dismissed", so don't key on it.)
    static func shouldSoundInAppAlarm(for payload: TimerPayload) -> Bool {
        guard payload.alarmEnabled else { return false }
        switch payload.kind {
        case .countdown:
            return true
        case .timer:
            return AlarmManager.shared.authorizationState != .authorized
        }
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

            switch payload.kind {
            case .countdown:
                NotificationScheduler.scheduleAlert(for: payload)
            case .timer where !payload.alarmEnabled:
                // "Alarm" toggle off: a quiet notification, never AlarmKit.
                NotificationScheduler.scheduleAlert(for: payload)
            case .timer:
                if await scheduleAlarm(for: payload) == false {
                    // AlarmKit unavailable / denied / at capacity. A local
                    // notification is a weaker alarm (one-shot, obeys the silent
                    // switch) but beats finishing a timer in silence — same
                    // philosophy as NotificationScheduler's own denial fallback.
                    NotificationScheduler.scheduleAlert(for: payload)
                }
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
        for index in timers.indices where timers[index].kind == .timer && timers[index].isFinished {
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
            metadata: TimerAlarmMetadata(timerID: payload.id, label: payload.label),
            tintColor: TimerKind.timer.accentColor
        )

        // preAlert from `remaining` so a resumed / extended timer fires at the right
        // moment; postAlert from `duration` so the panel's Repeat restarts the
        // *original* length, not whatever was left when it finished. The asymmetry is
        // deliberate.
        let config = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>(
            countdownDuration: .init(preAlert: payload.remaining, postAlert: payload.duration),
            attributes: attributes,
            sound: .named("alarm.caf")
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
