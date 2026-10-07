//
//  TimerArming.swift
//  sharedTimer
//
//  The one "arm this payload's finish alert" sequence every main-app mutation path
//  runs after `TimerStore.save` — ContentView, AppDelegate (CloudKit push + the
//  vibration-fallback notification's Repeat), WatchSyncController's relay, and the
//  App Intents. Used to be re-inlined at each of those sites; keep it here so a change
//  to the routing (see AlarmController.ownsAlert) lands everywhere at once.
//
//  Main app target only (reaches AlarmController). Like AlarmController, never call it
//  from TimerStore.swift.
//

import Foundation

enum TimerArming {
    /// AlarmKit alarm when either toggle is on, local notification when both are off
    /// (AlarmController picks), plus the custom Live Activity only for that both-off
    /// case — AlarmKit runs its own Live Activity whenever it owns the alert, so
    /// starting ours too would double it up (the "too many Live Activities" bug).
    /// Paused/expired payloads are handled inside `reschedule`.
    static func arm(_ payload: TimerPayload) {
        AlarmController.reschedule(for: payload)
        armLiveActivity(for: payload)
    }

    /// Same as `arm`, but awaits the (re)scheduling — for an intent's `perform()`, which
    /// the system may tear down the instant it returns (see CLAUDE.md,
    /// `rescheduleAwaiting`).
    static func armAwaiting(_ payload: TimerPayload) async {
        await AlarmController.rescheduleAwaiting(for: payload)
        armLiveActivity(for: payload)
    }

    private static func armLiveActivity(for payload: TimerPayload) {
        guard !AlarmController.ownsAlert(for: payload) else { return }
        if payload.isPaused {
            LiveActivityController.update(for: payload)
        } else {
            LiveActivityController.start(for: payload)
        }
    }
}
