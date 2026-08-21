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

    /// TimerPayload.compose computes duration as max(1, minutes * 60) — zero/negative
    /// minutes would silently yield a 1s, instantly-expired timer instead of an error.
    /// Same failure shape StartCountdownIntent guards against below.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard minutes > 0 else {
            throw TimerIntentError.nonPositiveMinutes
        }
        let payload = TimerPayload.compose(label: label, kind: .timer, minutes: minutes, targetDate: Date())
        TimerStore.save(payload)
        NotificationScheduler.scheduleAlert(for: payload)
        LiveActivityController.start(for: payload)
        return .result(dialog: "Started \(label) for \(Int(minutes)) minutes.")
    }
}

struct StartCountdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Countdown"

    @Parameter(title: "Label", default: "Countdown") var label: String
    @Parameter(title: "Target Date") var targetDate: Date

    /// TimerPayload.compose computes duration as max(1, targetDate.timeIntervalSinceNow)
    /// for .countdown — a past/near-now date would silently yield a 1s, instantly-expired
    /// countdown. NewTimerSheet/TimerComposeView dodge this with a date picker defaulted
    /// 24h out; a Siri/Shortcuts caller has no such guardrail, so reject it explicitly.
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard targetDate > Date() else {
            throw TimerIntentError.pastTargetDate
        }
        let payload = TimerPayload.compose(label: label, kind: .countdown, minutes: 0, targetDate: targetDate)
        TimerStore.save(payload)
        NotificationScheduler.scheduleAlert(for: payload)
        LiveActivityController.start(for: payload)
        return .result(dialog: "Counting down to \(label).")
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
