//
//  TimerIntents.swift
//  sharedTimer
//
//  Siri / Shortcuts support — see CLAUDE.md's Phase 3 (partial) plan. Main app target
//  only: this reuses ContentView's own creation path (TimerPayload.compose ->
//  TimerStore.save -> NotificationScheduler -> LiveActivityController), the same
//  sequence NewTimerSheet and MessagesViewController.send already use elsewhere.
//
//  Deliberately doesn't share the created timer — there's no background-intent API that
//  can address a specific iMessage contact and insert text the way MessagesViewController
//  does; that machinery is extension-only and tied to a live MSConversation. A freshly
//  created timer has no CloudLink yet, so CloudSyncController.pushUp would no-op anyway;
//  sharing stays a one-tap follow-up via the existing ShareTimerSheet.
//

import AppIntents
import Foundation

struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Timer"

    @Parameter(title: "Label", default: "Timer") var label: String
    @Parameter(title: "Minutes", default: 5) var minutes: Double
    @Parameter(title: "Alarm", default: true) var alarm: Bool
    @Parameter(title: "Vibrate", default: true) var vibrate: Bool

    /// TimerPayload.compose computes duration as max(1, minutes * 60) — zero/negative
    /// minutes would silently yield a 1s, instantly-expired timer instead of an error.
    /// Same failure shape StartCountdownIntent guards against below.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard minutes > 0 else {
            throw TimerIntentError.nonPositiveMinutes
        }
        let payload = TimerPayload.compose(label: label, kind: .timer, minutes: minutes, targetDate: Date(), alarmEnabled: alarm, vibrationEnabled: vibrate)
        TimerStore.save(payload)
        // Either toggle on -> AlarmKit (rings through silent/Focus, Stop/Repeat panel,
        // its own Live Activity). Both off -> a quiet notification + the custom Live
        // Activity.
        AlarmController.reschedule(for: payload)
        if !AlarmController.ownsAlert(for: payload) {
            LiveActivityController.start(for: payload)
        }
        return .result(dialog: "Started \(label) for \(Int(minutes)) minutes.")
    }
}

struct StartCountdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Countdown"

    @Parameter(title: "Label", default: "Countdown") var label: String
    @Parameter(title: "Target Date") var targetDate: Date
    @Parameter(title: "Alarm", default: true) var alarm: Bool
    @Parameter(title: "Vibrate", default: true) var vibrate: Bool

    /// TimerPayload.compose computes duration as max(1, targetDate.timeIntervalSinceNow)
    /// for .countdown — a past/near-now date would silently yield a 1s, instantly-expired
    /// countdown. NewTimerSheet/TimerComposeView dodge this with a date picker defaulted
    /// 24h out; a Siri/Shortcuts caller has no such guardrail, so reject it explicitly.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard targetDate > Date() else {
            throw TimerIntentError.pastTargetDate
        }
        let payload = TimerPayload.compose(label: label, kind: .countdown, minutes: 0, targetDate: targetDate, alarmEnabled: alarm, vibrationEnabled: vibrate)
        TimerStore.save(payload)
        // Either toggle on -> AlarmKit (rings through silent/Focus, its own Live
        // Activity). Both off -> a quiet notification + the custom Live Activity.
        // AlarmController picks; same arming sequence as ContentView.armAlerts.
        AlarmController.reschedule(for: payload)
        if !AlarmController.ownsAlert(for: payload) {
            LiveActivityController.start(for: payload)
        }
        return .result(dialog: "Counting down to \(label).")
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
/// several phases in one call. `steppedToNextPhase` always lands on exactly the next
/// phase, timed from the moment of the tap.
struct AdvanceSequenceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Advance Sequence"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        var all = TimerStore.loadAll()
        guard let index = all.firstIndex(where: { $0.id == timerID }) else { return .result() }
        let advanced = all[index].steppedToNextPhase()
        all[index] = advanced
        TimerStore.save(advanced)
        await AlarmController.rescheduleAwaiting(for: advanced)
        // A `LiveActivityIntent` runs in-process when the app happens to already be
        // foreground — same process as ContentView's own `@State timers` array, which
        // this mutation bypasses entirely (it writes straight to `TimerStore`).
        // Without this, tapping "Next" while the app is the frontmost app looks like it
        // does nothing: TimerStore/AlarmKit are correctly updated, but ContentView (and
        // an open TimerDetailView) keep showing the stale pre-advance phase until the
        // app backgrounds and refocuses, which is what naturally reloads from
        // TimerStore and hid this bug when a different app was frontmost instead.
        // `.externalTimerStoreChange` already exists for exactly this class of problem
        // (a watch/CloudKit mutation landing while foregrounded) and both call sites
        // that need to react to it already listen — see ContentView.swift.
        //
        // Confirmed on device: `perform()` runs off the main thread (SwiftUI logged
        // "Publishing changes from background threads is not allowed"). Posting on the
        // default queue delivered `.onReceive`'s closure — which sets `@State
        // timers` — on that same background thread, undefined behavior for SwiftUI
        // state; this, not a failure of the intent to run at all, was the real cause
        // of "Next looks like nothing happened" while the app was frontmost. Must post
        // from the main actor.
        await MainActor.run {
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        }
        return .result()
    }
}

/// AlarmKit `secondaryIntent` for the final phase of the final loop's alert — the
/// "Cancel" version of the button `AdvanceSequenceIntent` above wires to "Next" for
/// every other phase (see `AlarmController.scheduleAlarm`'s alert-construction
/// comment: `AlarmPresentation.Alert` has exactly one `secondaryButton` slot, so this
/// one button dynamically switches label + intent based on whether there's a next
/// phase to advance to). Marks the whole sequence exhausted — `loopIndex = loopCount`,
/// the same convention `TimerPayload.advancedSequence(at:)` already uses when a
/// sequence runs out on its own — rather than scheduling anything new.
struct EndSequenceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Sequence"

    @Parameter(title: "Timer ID") var timerID: String

    init() { self.timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    func perform() async throws -> some IntentResult {
        var all = TimerStore.loadAll()
        guard let index = all.firstIndex(where: { $0.id == timerID }),
              var sequence = all[index].sequence else { return .result() }
        sequence.loopIndex = sequence.loopCount
        all[index].sequence = sequence
        TimerStore.save(all[index])
        await NotificationScheduler.cancel(id: timerID)
        await AlarmController.cancelSequenceAlarm(id: timerID)
        // Same in-process-when-frontmost reasoning as AdvanceSequenceIntent above, and
        // the same fix: `perform()` runs off the main thread, so this must post from
        // the main actor or the `.onReceive` handler's `@State` write is undefined
        // behavior (confirmed on device via SwiftUI's "Publishing changes from
        // background threads" warning).
        await MainActor.run {
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        }
        return .result()
    }
}

enum TimerIntentError: LocalizedError {
    case pastTargetDate
    case nonPositiveMinutes

    var errorDescription: String? {
        switch self {
        case .pastTargetDate: return "That date has already passed — pick one in the future."
        case .nonPositiveMinutes: return "Minutes has to be more than zero."
        }
    }
}

/// Static phrases only — AppShortcutPhrase interpolation accepts \(.applicationName) plus
/// resolvable AppEnum/AppEntity parameters; free-text (label) and numeric (minutes)
/// parameters can't be spoken-phrase-filled. Siri prompts for them after the static
/// phrase matches, or they come from the Shortcuts app editor.
struct TimerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: ["Start a timer in \(.applicationName)"],
            shortTitle: "Start Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: StartCountdownIntent(),
            phrases: ["Start a countdown in \(.applicationName)"],
            shortTitle: "Start Countdown",
            systemImageName: "calendar"
        )
    }
}
