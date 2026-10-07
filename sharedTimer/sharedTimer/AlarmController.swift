//
//  AlarmController.swift
//  sharedTimer
//
//  AlarmKit bridge — MAIN APP TARGET ONLY. This deliberately breaks CLAUDE.md's
//  "shared logic lives in Shared/" rule: AlarmKit is unavailable in app
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
//  is smuggled in as a named asset rather than omitted — confirmed on a physical
//  device that AlarmKit's alert vibration isn't decoded from the audio waveform, same
//  as a regular notification's haptic: a silent asset still rings full-screen with
//  vibration and no audible tone. Both toggles off -> NotificationScheduler: a quiet,
//  standard-sound notification, no AlarmKit at all.
//
//  AlarmKit's own countdown Live Activity replaces the custom per-timer
//  TimerActivityAttributes Live Activity whenever AlarmKit owns the alert — call sites
//  only start the custom one when `!AlarmController.ownsAlert(for:)` (see
//  ContentView.armAlerts).
//

import ActivityKit
import AlarmKit
import AppIntents
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

    /// True only when AlarmKit is actually presenting its own interactive alert for
    /// this payload right now — `ownsAlert` alone isn't enough, since it stays true
    /// even when AlarmKit is denied/unavailable and `reschedule` fell back to
    /// `NotificationScheduler` (a plain notification, nothing interactive to protect).
    /// Callers that re-derive a just-finished sequence payload on a live tick
    /// (`ContentView.checkForNewlyExpired`, `TimerDetailView`'s own tick) persist the
    /// advance but skip `reschedule` while this is true. Back when every phase shared
    /// one alarm id, rescheduling there cancelled AlarmKit's just-presented alert out
    /// from under the user within about a second (confirmed on device). Per-phase ids
    /// make that structurally impossible now (only indices >= the new current one are
    /// cancelled), but the following phases are already pre-armed anyway, so the tick
    /// keeps its hands off AlarmKit entirely while an alert is up.
    static func alarmKitOwnsAlert(for payload: TimerPayload) -> Bool {
        ownsAlert(for: payload) && AlarmManager.shared.authorizationState == .authorized
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
    /// safe to call repeatedly — work is serialized per timer id, in call order (see
    /// `enqueue`). Nothing is dropped: every call runs, chained after the previous one.
    static func reschedule(for payload: TimerPayload) {
        // Cancel the notification synchronously so a .timer that just switched away
        // from the notification path can't leave a stale one armed.
        NotificationScheduler.cancel(id: payload.id)
        enqueue(payload.id) { await performReschedule(for: payload) }
    }

    /// Awaitable core of `reschedule`, for a caller that must not return before the
    /// (re)scheduling has actually completed — `AdvanceSequenceIntent` and the start
    /// intents. `reschedule`'s normal callers are fire-and-forget on purpose: the app
    /// process stays alive regardless, so the per-id-serialized `enqueue` Task is free
    /// to finish on its own time. An intent's `perform()` has no such guarantee — the
    /// system may tear down its execution the instant `perform()` returns, and calling
    /// the fire-and-forget `reschedule` and returning immediately gave
    /// `AlarmManager.schedule()` no reliable chance to actually run (confirmed on
    /// device: tapping "Next" on a sequence phase's alert never armed the next phase).
    /// Goes through the same per-id serializer as `reschedule` and awaits its turn, so
    /// a sequence's multi-alarm reschedule can't interleave with a concurrent
    /// foreground one for the same id. A `LiveActivityIntent` runs in-process, so when
    /// the app is foreground this is the *same* process as `ContentView` (see
    /// `AdvanceSequenceIntent`'s own `.externalTimerStoreChange` post).
    static func rescheduleAwaiting(for payload: TimerPayload) async {
        NotificationScheduler.cancel(id: payload.id)
        await Serializer.shared.runAndWait(payload.id) { await performReschedule(for: payload) }
    }

    private static func performReschedule(for payload: TimerPayload) async {
        if payload.sequence != nil {
            await performSequenceReschedule(for: payload)
            return
        }
        if payload.isPaused, payload.remaining > 0, ownsAlert(for: payload), await armPaused(payload, id: alarmID(for: payload.id)) {
            TimerStore.setAlarmKitArmed(id: payload.id, true)
            return
        }
        await cancelAlarm(id: payload.id)
        // Pessimistic until AlarmKit actually accepts the alarm below — every early
        // return leaves no AlarmKit alarm armed, so extensions must arm their own.
        TimerStore.setAlarmKitArmed(id: payload.id, false)

        guard !payload.isPaused, payload.remaining > 0 else { return }

        guard ownsAlert(for: payload) else {
            // Both toggles off: a quiet notification, never AlarmKit.
            NotificationScheduler.scheduleAlert(for: payload)
            return
        }
        if await scheduleAlarm(for: payload, id: alarmID(for: payload.id)) == .scheduled {
            TimerStore.setAlarmKitArmed(id: payload.id, true)
        } else {
            // AlarmKit unavailable / denied / at capacity. A local notification is
            // a weaker alarm (one-shot, obeys the silent switch) but beats
            // finishing a timer in silence — same philosophy as
            // NotificationScheduler's own denial fallback.
            NotificationScheduler.scheduleAlert(for: payload)
        }
    }

    // MARK: - Sequence pre-armed window

    /// How many phase occurrences (current + following) get their own AlarmKit alarm
    /// ahead of time. Bounded because AlarmKit has an undocumented per-app cap
    /// (`maximumLimitReached`) shared with every other timer; the window refills
    /// whenever the app reschedules this sequence (open/foreground/Next/any mutation).
    static let sequenceWindow = 8

    /// A sequence arms one AlarmKit alarm per upcoming phase occurrence, each with its
    /// own id (`phaseAlarmID`), instead of one alarm re-armed by the app at every
    /// boundary. Before this, tapping the primary Stop on a phase alert (rather than
    /// "Next") left nothing armed for the following phase until the app next ran — a
    /// locked phone never rang again for the rest of the sequence.
    ///
    /// - An earlier occurrence's alarm is never cancelled while it's *alerting*, so the
    ///   alert for the phase that just finished (index current-1 once advanced) is never
    ///   touched — that's what lets onAppear/scenePhase re-arm right after the app was
    ///   opened from a ringing phase alert without killing it. Earlier occurrences still
    ///   counting down/scheduled/paused are stale (e.g. skipped by "Next") and cancelled.
    /// - An existing alarm whose `.fixed` date and preAlert already match is kept, not
    ///   cancelled and re-created, so re-arming an unchanged sequence is a no-op for
    ///   AlarmKit (no Live Activity flicker). Matching uses a 1s tolerance — AlarmKit
    ///   isn't guaranteed to round-trip `Date` exactly.
    /// - The current phase keeps the exact config plain timers use (`preAlert:
    ///   remaining`, no schedule) unless pending; only *future* occurrences, whose
    ///   countdown window hasn't started yet, get `.fixed(end)` + `preAlert: duration`
    ///   — the one `.fixed` combination confirmed on device (see `scheduleAlarm`).
    private static func performSequenceReschedule(for payload: TimerPayload) async {
        guard let sequence = payload.sequence, let current = payload.sequenceGlobalIndex else { return }
        let total = sequence.phases.count * sequence.loopCount
        let existing = Dictionary(((try? AlarmManager.shared.alarms) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let window = (payload.isPaused || payload.remaining <= 0) ? [] : payload.upcomingSequencePhases(limit: sequenceWindow)
        let now = Date()
        let currentID = phaseAlarmID(timerID: payload.id, globalIndex: current)
        var kept: Set<UUID> = []
        // Paused: keep the current phase's alarm alive in AlarmKit's paused state (its
        // Live Activity shows Resume); every later pre-armed phase is cancelled below,
        // since their fixed dates no longer hold — resuming re-arms the whole window.
        if payload.isPaused, payload.remaining > 0, ownsAlert(for: payload), await armPaused(payload, id: currentID) {
            kept.insert(currentID)
        }
        var toSchedule: [(occurrence: ScheduledPhase, projected: TimerPayload, id: UUID, fixedAt: Date?)] = []
        for (offset, occurrence) in window.enumerated() {
            let id = phaseAlarmID(timerID: payload.id, globalIndex: occurrence.globalIndex)
            let projected: TimerPayload
            let fixedAt: Date?
            if offset == 0 {
                projected = payload
                fixedAt = payload.isPending() ? payload.endDate : nil
            } else {
                // Countdown window must still lie in the future — never `.fixed` a
                // phase whose countdown would already be running (unverified behavior).
                guard occurrence.endDate.addingTimeInterval(-occurrence.phase.duration) > now else { continue }
                projected = payload.materializingPhase(globalIndex: occurrence.globalIndex, startingAt: occurrence.endDate.addingTimeInterval(-occurrence.phase.duration))
                fixedAt = occurrence.endDate
            }
            guard ownsAlert(for: projected) else { continue }
            if let alarm = existing[id], matchesPrearmed(alarm, endDate: occurrence.endDate, duration: occurrence.phase.duration) {
                kept.insert(id)
                continue
            }
            toSchedule.append((occurrence, projected, id, fixedAt))
        }

        // Cancel everything from the current occurrence onward that isn't being kept,
        // plus the single-id alarm 1.0.3 and earlier used for every sequence phase.
        var stale: [UUID] = [alarmID(for: payload.id)]
        if current < total {
            stale += (current..<total).map { phaseAlarmID(timerID: payload.id, globalIndex: $0) }
        }
        // Earlier occurrences are over as far as the model is concerned — cancel any
        // still counting down / scheduled / paused (e.g. "Next" tapped on the Live
        // Activity mid-phase left the skipped phase's alarm running: two cards, and it
        // would still have rung). Only one actually *alerting* is left alone: that's
        // the just-finished phase's alert the user hasn't dismissed yet.
        stale += (0..<min(current, total)).map { phaseAlarmID(timerID: payload.id, globalIndex: $0) }
            .filter { existing[$0].map { $0.state != .alerting } ?? false }
        for id in stale where existing[id] != nil && !kept.contains(id) {
            try? AlarmManager.shared.cancel(id: id)
        }

        var currentArmed = kept.contains(currentID)
        for entry in toSchedule {
            let result = await scheduleAlarm(for: entry.projected, id: entry.id, fixedAt: entry.fixedAt)
            if entry.id == currentID {
                currentArmed = result == .scheduled
                if result != .scheduled {
                    // Same fallback as a plain timer, for the phase that's actually
                    // running now. Later phases simply wait for the next reschedule.
                    NotificationScheduler.scheduleAlert(for: payload)
                }
            }
            if result == .limitReached {
                print("AlarmController: AlarmKit alarm limit reached pre-arming \(payload.id) at phase occurrence \(entry.occurrence.globalIndex)")
            }
            if result != .scheduled && entry.id != currentID { break }
        }
        TimerStore.setAlarmKitArmed(id: payload.id, currentArmed)
        if !window.isEmpty, !ownsAlert(for: payload) {
            // Current phase has both toggles off: a quiet notification, never AlarmKit.
            NotificationScheduler.scheduleAlert(for: payload)
        }
    }

    /// Paused payload: keep an AlarmKit alarm alive in its paused state rather than
    /// cancelling it, so its Live Activity stays on the Lock Screen / Dynamic Island
    /// showing Resume (TimerAlarmActivityWidget) — like the Clock app's timer. True
    /// when an alarm for `id` is now paused at the payload's `pausedRemaining`.
    /// - Running alarm → `AlarmManager.pause(id:)` in place.
    /// - Already paused at the same remaining time → left alone.
    /// - Paused at a *different* time (extended while paused), or no alarm at all →
    ///   AlarmKit can't edit a paused alarm's duration, so a fresh alarm counting down
    ///   the new remaining time is scheduled and paused straight away. Before this the
    ///   paused card kept showing the pre-extend time until resume.
    /// The remaining time each alarm was paused at is recorded per alarm id, since
    /// `Alarm` doesn't expose its elapsed time. Resuming goes through the normal path:
    /// a paused alarm doesn't match a fresh config, so it's cancelled and re-created.
    private static func armPaused(_ payload: TimerPayload, id: UUID) async -> Bool {
        guard let remaining = payload.pausedRemaining, remaining > 0 else { return false }
        let existing = (try? AlarmManager.shared.alarms)?.first(where: { $0.id == id })
        switch existing?.state {
        case .paused?:
            if let recorded = pausedRemaining(for: id), abs(recorded - remaining) < 1 { return true }
            try? AlarmManager.shared.cancel(id: id)
        case .countdown?:
            if (try? AlarmManager.shared.pause(id: id)) != nil {
                recordPausedRemaining(remaining, for: id)
                return true
            }
            try? AlarmManager.shared.cancel(id: id)
        case .some:
            try? AlarmManager.shared.cancel(id: id)
        case nil:
            break
        }
        guard await scheduleAlarm(for: payload, id: id) == .scheduled else { return false }
        guard (try? AlarmManager.shared.pause(id: id)) != nil else {
            try? AlarmManager.shared.cancel(id: id)
            return false
        }
        recordPausedRemaining(remaining, for: id)
        return true
    }

    private static let pausedRemainingKey = "alarmPausedRemaining"

    private static func pausedRemaining(for id: UUID) -> TimeInterval? {
        (UserDefaults(suiteName: "group.com.lokesh.sharedTimer")?.dictionary(forKey: pausedRemainingKey) as? [String: Double])?[id.uuidString]
    }

    /// Also prunes entries for alarms AlarmKit no longer holds, so this stays tiny.
    private static func recordPausedRemaining(_ remaining: TimeInterval, for id: UUID) {
        guard let defaults = UserDefaults(suiteName: "group.com.lokesh.sharedTimer") else { return }
        let live = Set(((try? AlarmManager.shared.alarms) ?? []).map(\.id.uuidString))
        var map = (defaults.dictionary(forKey: pausedRemainingKey) as? [String: Double] ?? [:]).filter { live.contains($0.key) }
        map[id.uuidString] = remaining
        defaults.set(map, forKey: pausedRemainingKey)
    }

    /// True when `alarm` is already the pre-armed `.fixed` alarm for this occurrence.
    private static func matchesPrearmed(_ alarm: Alarm, endDate: Date, duration: TimeInterval) -> Bool {
        guard case .fixed(let date)? = alarm.schedule,
              abs(date.timeIntervalSince(endDate)) < 1,
              let preAlert = alarm.countdownDuration?.preAlert,
              abs(preAlert - duration) < 1 else { return false }
        return true
    }

    /// Full teardown for a deleted timer, by id alone — for callers that only have an
    /// id (CloudKit/watch deletes, which never carry sequences). Prefer `clear(_:)`
    /// whenever the payload is at hand.
    static func clear(id: String) {
        NotificationScheduler.cancel(id: id)
        TimerStore.setAlarmKitArmed(id: id, false)
        enqueue(id) { await cancelAlarm(id: id) }
    }

    /// Full teardown for a deleted timer, including every pre-armed phase alarm of a
    /// sequence (which `clear(id:)` can't enumerate without the sequence's shape).
    static func clear(_ payload: TimerPayload) {
        NotificationScheduler.cancel(id: payload.id)
        TimerStore.setAlarmKitArmed(id: payload.id, false)
        enqueue(payload.id) { await cancelAllAlarms(for: payload) }
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
        // A sequence-owning payload never reaches this via AlarmKit's "Repeat" (that
        // button is suppressed in scheduleAlarm for any sequence phase), so seeing one
        // `isFinished` here just means it hasn't been re-derived yet by
        // `advancedSequence` — which callers must run *before* this, not after. Only
        // treat it as legitimately "revive from an AlarmKit repeat" once the whole
        // sequence is exhausted.
        for index in timers.indices where timers[index].isFinished
            && (timers[index].sequence == nil || timers[index].sequence!.loopIndex >= timers[index].sequence!.loopCount) {
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

    private enum ScheduleResult { case scheduled, limitReached, failed }

    /// `fixedAt` non-nil pins the alert to that date with a `duration`-long countdown
    /// before it (`schedule: .fixed`) — used for a pending sequence's first phase and
    /// for every pre-armed future phase occurrence; nil is the plain "count down
    /// `remaining` from now" config every running timer uses.
    private static func scheduleAlarm(for payload: TimerPayload, id: UUID, fixedAt: Date? = nil) async -> ScheduleResult {
        guard await ensureAuthorized() else { return .failed }

        // A sequence phase never gets AlarmKit's own built-in "Repeat": `.countdown`
        // behavior can only restart the SAME `postAlert` duration, which would
        // silently re-run the phase that just finished instead of advancing to the
        // next one. It still needs a real `secondaryButton`, though — an
        // `Alert(title:)` with no secondary button was confirmed on-device to not
        // present interactively at all outside the lock screen (see the `stopIntent`
        // note below for the related, now-fixed bug).
        //
        // `AlarmPresentation.Alert` has exactly one `secondaryButton` slot (the primary
        // Stop control is a fixed OS button — `Alert.stopButton` is deprecated/unused
        // in the current SDK, no label or action of ours) — so "Next" and "Cancel"
        // can't both be on screen. Instead this one button dynamically becomes
        // "Cancel" on the final phase of the final loop and "Next" otherwise, which
        // happens to satisfy the actual product requirement exactly: Next disabled/
        // hidden with only Cancel available once there's nothing left to advance to.
        // Cancelling mid-sequence (before the final phase) isn't available from this
        // alert — only the primary Stop, which just dismisses and lets the sequence
        // continue on next app foreground, same as it always has.
        let isFinalSequencePhase = payload.sequence.map {
            $0.phaseIndex == $0.phases.count - 1 && $0.loopIndex == $0.loopCount - 1
        } ?? false
        let alert: AlarmPresentation.Alert
        if payload.sequence != nil {
            let button = isFinalSequencePhase
                ? AlarmButton(text: "Cancel", textColor: .white, systemImageName: "xmark")
                : AlarmButton(text: "Next", textColor: .white, systemImageName: "forward.fill")
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: payload.label),
                secondaryButton: button,
                secondaryButtonBehavior: .custom
            )
        } else {
            // AlarmKit derives the Stop control from the alert itself; we only supply
            // the secondary "Repeat" button. `.countdown` behavior makes AlarmKit
            // restart the countdown (for `postAlert` seconds) with no intent of ours.
            let repeatButton = AlarmButton(text: "Repeat", textColor: .white, systemImageName: "repeat")
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: payload.label),
                secondaryButton: repeatButton,
                secondaryButtonBehavior: .countdown
            )
        }
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: payload.label)
        )
        // A Paused presentation is what lets `AlarmManager.pause(id:)` keep the alarm
        // (and its Live Activity, now with a Resume button) alive while the timer is
        // paused, instead of the alarm being cancelled — see `performReschedule`. No
        // `pauseButton` on Countdown: that would let the system pause the alarm without
        // running any of our code, desyncing TimerStore; our own Live Activity buttons
        // (LiveActivityIntents.swift) drive pause/resume instead.
        let paused = AlarmPresentation.Paused(
            title: LocalizedStringResource(stringLiteral: payload.label),
            resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")
        )
        let presentation = AlarmPresentation(alert: alert, countdown: countdown, paused: paused)

        let attributes = AlarmAttributes<TimerAlarmMetadata>(
            presentation: presentation,
            metadata: TimerAlarmMetadata(
                timerID: payload.id, label: payload.label, kind: payload.kind,
                sequenceCaption: payload.sequenceCaption,
                phaseIndex: payload.sequenceGlobalIndex,
                isFinalPhase: payload.sequence == nil ? nil : isFinalSequencePhase
            ),
            tintColor: payload.kind.accentColor
        )

        // preAlert from `remaining` so a resumed / extended timer fires at the right
        // moment; postAlert from `duration` so the panel's Repeat restarts the
        // *original* length, not whatever was left when it finished. The asymmetry is
        // deliberate.
        //
        // A pending sequence (isPending()) is the one exception: `remaining` there is
        // wait-plus-duration, and a plain `preAlert: remaining` countdown makes
        // AlarmKit's own Live Activity/Dynamic Island appear the instant this is
        // scheduled -- days before the sequence even starts, confirmed on device. Pin
        // the actual fire date instead with `schedule: .fixed(payload.endDate)`
        // (endDate is already start + phase 0's duration -- see composeSequence) and
        // keep `preAlert: payload.duration` so the countdown/Live Activity only
        // appears for the last `duration` seconds before that date, i.e. starting
        // right at the scheduled start. This combination isn't documented (beta API,
        // checked against the swiftinterface, not behavior) -- verify on device that
        // the alarm rings at `endDate`, not `endDate + duration`, before trusting it.
        let scheduleOverride: Alarm.Schedule? = fixedAt.map { .fixed($0) }
        // Loud alarm.caf when the alarm toggle is on; otherwise (vibration-only)
        // vibration_silent.caf — a digitally-silent .caf of the same format/duration.
        // AlarmKit's `sound:` param is non-optional and has no explicit "no sound"
        // case (checked against the real API — see the file header). Confirmed on a
        // physical device: the alert's system vibration isn't decoded from the audio
        // waveform, same as a regular notification's haptic firing independent of
        // which sound plays — a silent asset gets the full-screen alert + vibration +
        // Stop/Repeat panel with no audible tone, exactly as intended.
        // `stopIntent` (the PRIMARY Stop control's action) must stay nil — confirmed
        // on-device that a non-nil `stopIntent` makes AlarmKit treat the whole alarm as
        // background-resolvable: it ran the intent and dismissed itself the instant the
        // alarm fired, with no full-screen alert and no user interaction at all,
        // silently "cancelling" every sequence phase alert. That was the original
        // (wrong) home for the sequence-advance logic. `secondaryIntent` — checked
        // against the real AlarmKit `.swiftinterface`, a distinct parameter from
        // `stopIntent` — is the actual hook for "run this when the SEPARATE secondary
        // button is tapped" and is what `secondaryButtonBehavior: .custom` above
        // pairs with; unlike `stopIntent` it doesn't appear to suppress presentation.
        // Confirmed unreliable when the app is frontmost (see `AdvanceSequenceIntent`'s
        // and `EndSequenceIntent`'s own doc comments and CLAUDE.md) — locked and
        // other-app-frontmost both work. Runs whichever intent matches the button
        // built above: `EndSequenceIntent` on the final phase, `AdvanceSequenceIntent`
        // otherwise. If it doesn't stick, a sequence still advances correctly on next
        // app foreground (the `advancedSequence` re-derivation guarantee).
        var secondaryIntent: (any LiveActivityIntent)?
        if payload.sequence != nil {
            secondaryIntent = isFinalSequencePhase
                ? EndSequenceIntent(timerID: payload.id)
                : AdvanceSequenceIntent(timerID: payload.id, phaseIndex: payload.sequenceGlobalIndex ?? -1)
        }
        let config = AlarmManager.AlarmConfiguration<TimerAlarmMetadata>(
            countdownDuration: .init(preAlert: fixedAt != nil ? payload.duration : payload.remaining, postAlert: payload.duration),
            schedule: scheduleOverride,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: secondaryIntent,
            sound: .named(payload.alarmEnabled ? "alarm.caf" : "vibration_silent.caf")
        )

        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
            return .scheduled
        } catch AlarmManager.AlarmError.maximumLimitReached {
            print("AlarmController: AlarmKit alarm limit reached for \(payload.id)")
            return .limitReached
        } catch {
            print("AlarmController: schedule failed for \(payload.id): \(error)")
            return .failed
        }
    }

    private static func cancelAlarm(id: String) async {
        do { try AlarmManager.shared.cancel(id: alarmID(for: id)) }
        catch { /* not scheduled, or already fired and dismissed — nothing to do */ }
    }

    /// Explicit cancel for `EndSequenceIntent`: every phase alarm of the sequence,
    /// including the one ringing right now (the user tapped its "Cancel"). Whatever
    /// state AlarmKit leaves a fired alarm in after its `.custom` secondary button
    /// resolves it, this makes sure it isn't left sitting in `.countdown` —
    /// `reconcileRepeat` treats an already-exhausted sequence with a live `.countdown`
    /// alarm as "user tapped the built-in Repeat" and would silently revive the very
    /// sequence this just ended, on next app open.
    static func cancelSequenceAlarms(for payload: TimerPayload) async {
        await cancelAllAlarms(for: payload)
        TimerStore.setAlarmKitArmed(id: payload.id, false)
    }

    /// Cancels the legacy single-id alarm and, for a sequence, every phase
    /// occurrence's alarm — filtered against one `alarms` read so a long sequence
    /// doesn't issue `phases × loops` blind cancels.
    private static func cancelAllAlarms(for payload: TimerPayload) async {
        var ids: Set<UUID> = [alarmID(for: payload.id)]
        if let sequence = payload.sequence {
            let total = sequence.phases.count * sequence.loopCount
            ids.formUnion((0..<total).map { phaseAlarmID(timerID: payload.id, globalIndex: $0) })
        }
        let existing = Set(((try? AlarmManager.shared.alarms) ?? []).map(\.id))
        for id in ids.intersection(existing) {
            try? AlarmManager.shared.cancel(id: id)
        }
    }

    /// AlarmKit keys alarms by UUID; TimerPayload.id is a String (a UUID string for
    /// locally created timers, but a shared link can carry any id). Use it directly
    /// when it parses, else derive a stable UUID from its bytes.
    private static func alarmID(for timerID: String) -> UUID {
        if let uuid = UUID(uuidString: timerID) { return uuid }
        return derivedUUID(timerID)
    }

    /// One sequence phase occurrence's own alarm id — stable for a given timer id and
    /// global index (loopIndex * phases.count + phaseIndex), distinct per index and
    /// from the legacy `alarmID(for:)`.
    static func phaseAlarmID(timerID: String, globalIndex: Int) -> UUID {
        derivedUUID("\(timerID)#\(globalIndex)")
    }

    /// Name-based (SHA-256, version 5 layout) UUID from arbitrary text.
    private static func derivedUUID(_ text: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(text.utf8)))  // 32 bytes
        let bytes: uuid_t = (d[0], d[1], d[2], d[3], d[4], d[5],
                             (d[6] & 0x0F) | 0x50, d[7],
                             (d[8] & 0x3F) | 0x80, d[9],
                             d[10], d[11], d[12], d[13], d[14], d[15])
        return UUID(uuid: bytes)
    }

    // MARK: - Per-id serialization

    /// Queues `work` behind everything already queued for `id`, in *call* order: the
    /// chaining happens synchronously under a lock at call time. The previous version
    /// hopped each call through its own unstructured `Task` before reaching an actor,
    /// and the order those Tasks reach it isn't specified — a `reschedule` quickly
    /// followed by `clear` (a fast change-then-delete) could run in reverse and leave
    /// an alarm armed for a deleted timer.
    @discardableResult
    private static func enqueue(_ id: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Serializer.shared.enqueue(id, work)
    }

    private final class Serializer: @unchecked Sendable {
        static let shared = Serializer()
        private let lock = NSLock()
        private var tail: [String: Task<Void, Never>] = [:]

        func enqueue(_ id: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
            lock.lock()
            defer { lock.unlock() }
            let previous = tail[id]
            let task = Task {
                await previous?.value
                await work()
            }
            tail[id] = task
            Task { [weak self] in
                await task.value
                self?.clear(id, ifTail: task)
            }
            return task
        }

        /// Same queue as `enqueue`, but returns only once `work` has finished — for
        /// `rescheduleAwaiting`.
        func runAndWait(_ id: String, _ work: @escaping @Sendable () async -> Void) async {
            await enqueue(id, work).value
        }

        private func clear(_ id: String, ifTail task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            if tail[id] == task { tail[id] = nil }
        }
    }
}
