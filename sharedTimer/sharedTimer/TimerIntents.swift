//
//  TimerIntents.swift
//  sharedTimer
//
//  Siri / Shortcuts support. Main app target only: start intents create timers;
//  existing-timer intents use TimerIntentActions to reload, validate, mutate, arm
//  and sync. TimerChoice is shared with the widget's configuration picker.
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
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard minutes.isFinite, minutes > 0, (minutes * 60).isFinite else {
            throw TimerIntentError.nonPositiveMinutes
        }
        let payload = TimerPayload.compose(label: label, kind: .timer, minutes: minutes, targetDate: Date(), alarmEnabled: alarm, vibrationEnabled: vibrate)
        TimerStore.save(payload)
        // Either toggle on -> AlarmKit (rings through silent/Focus, Stop/Repeat panel,
        // its own Live Activity). Both off -> a quiet notification + the custom Live
        // Activity.
        // Awaited, not the fire-and-forget `reschedule`: Siri can cold-launch the
        // process just to run this intent and tear it down the instant `perform()`
        // returns, same class of bug `AdvanceSequenceIntent` had — see CLAUDE.md.
        await TimerArming.armAwaiting(payload)
        RecentTimersStore.record(payload)
        RecentTimersSync.refresh()
        await announceExternalChange()
        return .result(dialog: "Started \(payload.label) for \(RecentTimer.lengthText(payload.duration)).")
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
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard targetDate > Date() else {
            throw TimerIntentError.pastTargetDate
        }
        let payload = TimerPayload.compose(label: label, kind: .countdown, minutes: 0, targetDate: targetDate, alarmEnabled: alarm, vibrationEnabled: vibrate)
        TimerStore.save(payload)
        // Either toggle on -> AlarmKit (rings through silent/Focus, its own Live
        // Activity). Both off -> a quiet notification + the custom Live Activity.
        // AlarmController picks; same arming sequence as ContentView.armAlerts.
        // Awaited, not the fire-and-forget `reschedule` -- same Siri-teardown risk as
        // StartTimerIntent above.
        await TimerArming.armAwaiting(payload)
        await announceExternalChange()
        return .result(dialog: "Counting down to \(payload.label).")
    }
}

/// A Siri/Shortcuts start writes straight to TimerStore, outside ContentView's own
/// mutation path — push it to the watch, and tell a foregrounded app to reload (from
/// the main actor; see CLAUDE.md's `.externalTimerStoreChange` notes).
private func announceExternalChange() async {
    await TimerSpotlightIndex.shared.refreshAwaiting()
    WatchSyncController.pushCurrentState()
    await MainActor.run {
        TimerShortcuts.updateAppShortcutParameters()
        NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
    }
}

enum TimerIntentError: LocalizedError, Equatable {
    case pastTargetDate
    case nonPositiveMinutes
    case timerNotFound
    case timerScheduled
    case timerFinished

    var errorDescription: String? {
        switch self {
        case .pastTargetDate: return "That date has already passed — pick one in the future."
        case .nonPositiveMinutes: return "Enter a finite number of minutes greater than zero."
        case .timerNotFound: return "That timer is no longer available. Choose another timer."
        case .timerScheduled: return "That sequence has not started yet. You can change it after it starts."
        case .timerFinished: return "That timer has finished. Repeat it in the app to start it again."
        }
    }
}

struct PauseTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Timer"
    static let description = IntentDescription("Pause a timer, countdown, or the current sequence phase.")
    @Parameter(title: "Timer") var timer: TimerChoice
    static var parameterSummary: some ParameterSummary { Summary("Pause \(\.$timer)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let payload = try await TimerIntentActions.perform(timerID: timer.id, mutation: .pause)
        return .result(dialog: "\(payload.label) is paused with \(TimerIntentActions.spokenTime(payload.remaining)) left.")
    }
}

struct ResumeTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Timer"
    static let description = IntentDescription("Resume a paused timer, countdown, or sequence phase.")
    @Parameter(title: "Timer") var timer: TimerChoice
    static var parameterSummary: some ParameterSummary { Summary("Resume \(\.$timer)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let payload = try await TimerIntentActions.perform(timerID: timer.id, mutation: .resume)
        return .result(dialog: "\(payload.label) is running with \(TimerIntentActions.spokenTime(payload.remaining)) left.")
    }
}

struct ExtendTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Extend Timer"
    static let description = IntentDescription("Add time to a running or paused timer, countdown, or current sequence phase.")
    @Parameter(title: "Timer") var timer: TimerChoice
    @Parameter(title: "Minutes", requestValueDialog: "How many minutes would you like to add?") var minutes: Double
    static var parameterSummary: some ParameterSummary { Summary("Extend \(\.$timer) by \(\.$minutes) minutes") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let payload = try await TimerIntentActions.perform(timerID: timer.id, mutation: .extend(minutes: minutes))
        if payload.isPaused {
            return .result(dialog: "Added \(TimerIntentActions.spokenTime(minutes * 60)) to \(payload.label). It is still paused with \(TimerIntentActions.spokenTime(payload.remaining)) left.")
        }
        return .result(dialog: "Added \(TimerIntentActions.spokenTime(minutes * 60)) to \(payload.label). \(TimerIntentActions.spokenTime(payload.remaining)) left.")
    }
}

struct GetTimerRemainingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Time Remaining"
    static let description = IntentDescription("Read a timer's remaining time. Returns seconds for use in other Shortcut actions; for sequences this is the current phase.")
    @Parameter(title: "Timer") var timer: TimerChoice
    static var parameterSummary: some ParameterSummary { Summary("Get time remaining on \(\.$timer)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let current = try TimerIntentActions.read(timerID: timer.id)
        let time = TimerIntentActions.spokenTime(current.seconds)
        switch current.status {
        case .scheduled:
            let start = current.payload.scheduledStartDate!.formatted(date: .abbreviated, time: .shortened)
            return .result(value: current.seconds, dialog: "\(current.payload.label) is scheduled to start \(start).")
        case .finished:
            return .result(value: 0, dialog: "\(current.payload.label) has finished.")
        case .paused:
            return .result(value: current.seconds, dialog: "\(current.payload.label) is paused with \(time) left.")
        case .running:
            return .result(value: current.seconds, dialog: "\(current.payload.label) has \(time) left.")
        }
    }
}

/// Entity parameters can be spoken in the phrase; Siri asks for numeric minutes
/// separately, or they can be configured in the Shortcuts editor.
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
        AppShortcut(
            intent: PauseTimerIntent(),
            phrases: ["Pause a timer in \(.applicationName)", "Pause \(\.$timer) in \(.applicationName)"],
            shortTitle: "Pause Timer",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeTimerIntent(),
            phrases: ["Resume a timer in \(.applicationName)", "Resume \(\.$timer) in \(.applicationName)"],
            shortTitle: "Resume Timer",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ExtendTimerIntent(),
            phrases: ["Extend a timer in \(.applicationName)", "Extend \(\.$timer) in \(.applicationName)"],
            shortTitle: "Extend Timer",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: GetTimerRemainingIntent(),
            phrases: ["How long is left in \(.applicationName)", "How long is left on \(\.$timer) in \(.applicationName)"],
            shortTitle: "Time Remaining",
            systemImageName: "clock"
        )
    }
}
