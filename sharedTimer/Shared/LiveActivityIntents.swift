//
//  LiveActivityIntents.swift
//  Shared
//
//  Every `LiveActivityIntent` a Live Activity / AlarmKit alert can fire. Compiled by
//  sharedTimer AND sharedTimerWidget (excluded from the Clip and Messages targets in
//  the project's Shared exception sets): the widget needs the types to build its
//  `Button(intent:)`s, but the system always runs a `LiveActivityIntent`'s `perform()`
//  in the *app's* process. So `perform()` only forwards to `LiveActivityActions`, which
//  has two same-named definitions — the real one in sharedTimer/LiveActivityActions.swift
//  (TimerStore + AlarmController + sync), and a no-op stub in
//  sharedTimerWidget/LiveActivityActions.swift that exists only so this file compiles
//  there (AlarmController/CloudKit must never be reachable from the widget).
//

import AppIntents
import Foundation

/// Lock-screen / Dynamic Island Pause ⇄ Resume button, on both the AlarmKit Live
/// Activity (TimerAlarmActivityWidget) and the custom one (TimerLiveActivityWidget).
struct ToggleTimerPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or Resume Timer"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.togglePause(timerID: timerID)
        return .result()
    }
}

/// Lock-screen / Dynamic Island ✕ button for a plain timer/countdown (sequences get
/// Next/Cancel instead): ends it now, silently — it moves to Finished in the app with
/// Repeat available, it is NOT deleted.
struct StopTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Timer"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.stop(timerID: timerID)
        return .result()
    }
}

/// Home-screen widget "Repeat" on a finished timer — restarts it in place (same id,
/// original length; a sequence restarts at phase 0), like the app's own Repeat.
struct RepeatTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Repeat Timer"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.repeatTimer(timerID: timerID)
        return .result()
    }
}

/// Control Center / Action button control and the home-screen Quick Actions: starts a
/// recent timer (RecentTimersStore) without opening the app. A `LiveActivityIntent`
/// for the same reason as everything else in this file — the system runs it in the
/// app's process, where AlarmKit is available (it isn't in the widget extension that
/// hosts the control). Empty `recentID` = the most recent one (or a 5-minute "Timer"
/// when there's no history yet).
struct StartRecentTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Recent Timer"

    @Parameter(title: "Recent", default: "") var recentID: String

    init() { self.recentID = "" }
    init(recentID: String) { self.recentID = recentID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.startRecent(id: recentID)
        return .result()
    }
}

/// AlarmKit `secondaryIntent` for a sequence phase's alarm — paired with
/// `secondaryButtonBehavior: .custom` on its `AlarmPresentation.Alert` (see
/// `AlarmController.scheduleAlarm`), not `stopIntent`: those are distinct parameters
/// on `AlarmConfiguration`, and the earlier version of this wired to `stopIntent`
/// instead, which made AlarmKit silently skip the interactive alert entirely — see
/// CLAUDE.md. A `LiveActivityIntent` runs in-process without opening any UI, same
/// mechanism Live Activity buttons use elsewhere on iOS: when the user taps "Next" on
/// a mid-sequence phase's fired alert, this advances to the next phase and arms its
/// alert without the app ever coming to the foreground.
///
/// Must call `AlarmController.rescheduleAwaiting`, not the fire-and-forget
/// `reschedule` — confirmed on device that calling `reschedule` and returning
/// immediately never actually armed the next phase's alarm: `reschedule` only kicks
/// off a detached Task and returns, which is fine while the app process stays alive on
/// its own, but here the system may tear down this intent's execution the instant
/// `perform()` returns, before that detached Task gets to run `AlarmManager.schedule`
/// at all. `rescheduleAwaiting` runs the same work inline and is awaited here instead.
///
/// Uses `TimerPayload.steppedToNextPhase()`, not `advancedSequence()` — confirmed on
/// device that reusing the date-based re-derivation function here made "Next" look
/// like it randomly ended the sequence: it chains the next phase's duration off the
/// stale original boundary, so any real delay between the alert firing and the tap
/// (trivially reached with short phase durations) makes it walk through, or exhaust,
/// several phases in one call. `materializingPhase` (what `steppedToNextPhase` is built
/// on) always lands on exactly the next phase, timed from the moment of the tap.
///
/// `phaseIndex` is the global index (loopIndex * phases.count + phaseIndex) of the
/// phase whose alert carried this button. Needed since phases are pre-armed (see
/// `AlarmController.performSequenceReschedule`): after a Stop (not Next) on phase k
/// with the app never opened, phase k+1's pre-armed alert rings while the stored
/// payload still sits on phase k — "Next" there must start k+2, not k+1. -1 (the
/// default, also what alarms scheduled by 1.0.3 decode to) means "the stored phase".
/// A tap on an alert the stored payload has already moved past is a no-op beyond
/// refreshing the UI.
struct AdvanceSequenceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Advance Sequence"

    @Parameter(title: "Timer ID") var timerID: String
    @Parameter(title: "Phase Index", default: -1) var phaseIndex: Int

    init() {
        self.timerID = ""
        self.phaseIndex = -1
    }
    init(timerID: String, phaseIndex: Int = -1) {
        self.timerID = timerID
        self.phaseIndex = phaseIndex
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.advanceSequence(timerID: timerID, phaseIndex: phaseIndex)
        return .result()
    }
}

struct EndSequenceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Sequence"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.endSequence(timerID: timerID)
        return .result()
    }
}
