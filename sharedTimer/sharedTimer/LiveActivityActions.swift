//
//  LiveActivityActions.swift
//  sharedTimer
//
//  The real work behind every `LiveActivityIntent` in Shared/LiveActivityIntents.swift
//  — Lock Screen / Dynamic Island buttons and the AlarmKit alert's Next/Cancel. The
//  system runs those intents in this (the app's) process, so they can reach
//  TimerStore, AlarmController and the sync controllers. The widget target compiles a
//  no-op stub with the same name instead (sharedTimerWidget/LiveActivityActions.swift).
//
//  Every action follows the same rules, each learned on device (see CLAUDE.md):
//  - Await the rescheduling (`TimerArming.armAwaiting` / `rescheduleAwaiting`), never
//    the fire-and-forget `reschedule` — the system may tear the intent down the instant
//    `perform()` returns, before a detached Task gets to talk to AlarmKit.
//  - The mutation bypasses ContentView's own mutation path (it writes straight to
//    TimerStore), so post `.externalTimerStoreChange` — or a foregrounded app keeps
//    showing stale state. And post it from the main actor: `perform()` runs off the
//    main thread, and NotificationCenter delivers on the posting thread, so posting
//    there made ContentView's `@State` write happen off-main (undefined behavior that
//    looked like "the button did nothing").
//

import Foundation
import UserNotifications

enum LiveActivityActions {

    /// Idempotent: the toggle sends the desired state, so a double tap or a stale
    /// card can't flip it the wrong way.
    static func setPaused(timerID: String, paused: Bool) async {
        guard let payload = stored(timerID), !payload.isFinished, !payload.isPending(),
              payload.isPaused != paused else { return await refreshUI() }
        let updated = paused ? payload.paused() : payload.resumed()
        await commit(updated, action: paused ? "paused" : "resumed")
    }

    /// Ends a plain timer/countdown right now, without alerting — it reads Finished
    /// in the app (Repeat available), it isn't deleted. On a sequence (only reachable
    /// from the custom Live Activity, where there's no Next/Cancel pair) it ends the
    /// whole sequence, same as `endSequence`.
    static func stop(timerID: String) async {
        guard let payload = stored(timerID), !payload.isFinished else { return await refreshUI() }
        if payload.sequence != nil {
            return await endSequence(timerID: timerID)
        }
        var updated = payload
        updated.endDate = Date()
        updated.pausedRemaining = nil
        updated.updatedAt = Date()
        // A deliberate stop is already "acknowledged" — never let the in-app
        // vibration fallback buzz for it on next open. (save() clears this flag, so
        // set it after.)
        TimerStore.save(updated)
        TimerStore.acknowledgeFinish(id: updated.id)
        await AlarmController.rescheduleAwaiting(for: updated)
        LiveActivityController.end(id: updated.id)
        CloudSyncController.pushUp(updated, action: "stopped")
        WatchSyncController.pushCurrentState()
        await refreshUI()
    }

    /// "Next" on a sequence phase's alert or Live Activity. `phaseIndex` is the global
    /// index of the phase whose alert/card carried the button (-1 = the stored phase —
    /// also what 1.0.3-scheduled alarms decode to). Uses `materializingPhase`, never
    /// `advancedSequence` — see AdvanceSequenceIntent's doc comment.
    static func advanceSequence(timerID: String, phaseIndex: Int) async {
        guard let payload = stored(timerID), let storedIndex = payload.sequenceGlobalIndex else { return await refreshUI() }
        let tappedIndex = phaseIndex >= 0 ? phaseIndex : storedIndex
        guard tappedIndex >= storedIndex else { return await refreshUI() }
        var advanced = payload.materializingPhase(globalIndex: tappedIndex + 1, startingAt: Date())
        // "Next" on a paused card starts the next phase running.
        advanced.pausedRemaining = nil
        TimerStore.save(advanced)
        await AlarmController.rescheduleAwaiting(for: advanced)
        WatchSyncController.pushCurrentState()
        await refreshUI()
    }

    /// "Cancel" on the final phase — marks the sequence exhausted (`loopIndex =
    /// loopCount`, the convention `advancedSequence` uses when one runs out on its
    /// own) and tears down every phase alarm, including the one ringing now.
    static func endSequence(timerID: String) async {
        guard var payload = stored(timerID), var sequence = payload.sequence else { return await refreshUI() }
        sequence.loopIndex = sequence.loopCount
        payload.sequence = sequence
        payload.pausedRemaining = nil
        TimerStore.save(payload)
        NotificationScheduler.cancel(id: timerID)
        await AlarmController.cancelSequenceAlarms(for: payload)
        LiveActivityController.end(id: timerID)
        WatchSyncController.pushCurrentState()
        await refreshUI()
    }

    /// Widget "Repeat" on a finished timer — same mutation as the app's Repeat.
    static func repeatTimer(timerID: String) async {
        guard let payload = stored(timerID), payload.isFinished else { return await refreshUI() }
        await commit(payload.repeated(), action: "repeated")
    }

    /// Control Center / Action button / Quick Action: start a recent timer now.
    static func startRecent(id: String) async {
        let recents = RecentTimersStore.all()
        let recent = recents.first { $0.id == id } ?? recents.first
        let payload = recent?.payload()
            ?? TimerPayload.compose(label: "Timer", kind: .timer, minutes: 5, targetDate: Date())
        TimerStore.setWidgetFocus(id: payload.id)
        TimerStore.save(payload)
        await TimerArming.armAwaiting(payload)
        RecentTimersStore.record(payload)
        await RecentTimersSync.refresh()
        WatchSyncController.pushCurrentState()
        announceStarted(payload)
        await refreshUI()
    }

    /// A Control Center / Action button tap has no visible result of its own — the
    /// app never opens. Confirm with a brief, silent banner ("Pasta started · ends
    /// 1:05 PM"), replaced (same identifier) if the control is tapped again.
    private static func announceStarted(_ payload: TimerPayload) {
        let content = UNMutableNotificationContent()
        content.title = "\(payload.label) started"
        content.body = "\(RecentTimer.lengthText(payload.duration)) · ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        content.sound = nil
        content.categoryIdentifier = startedCategoryID
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: "recent-timer-started", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Opts the start confirmation into a foreground banner too (AppDelegate.willPresent).
    static let startedCategoryID = "SHAREDTIMER_TIMER_STARTED"

    // MARK: - Helpers

    /// Every action goes through here first, so it also records the widget focus (see
    /// TimerStore.setWidgetFocus) before the mutation's save reloads the widgets.
    private static func stored(_ timerID: String) -> TimerPayload? {
        TimerStore.setWidgetFocus(id: timerID)
        return TimerStore.loadAll().first { $0.id == timerID }
    }

    private static func commit(_ updated: TimerPayload, action: String) async {
        TimerStore.save(updated)
        await TimerArming.armAwaiting(updated)
        CloudSyncController.pushUp(updated, action: action)
        WatchSyncController.pushCurrentState()
        await refreshUI()
    }

    private static func refreshUI() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        }
    }
}
