//
//  TimerFocusFilter.swift
//  sharedTimer
//
//  N10 (owner's picks A + suggestion, 2026-11-27, https://claude.ai/artifact/8xDPZqVcd77PMzccAiEXS8):
//  Settings → Focus → Focus Filters → Timer. Two switches, both off by default: heads-up
//  reminders and shared-timer updates. iOS applies `appContext` itself — matching each
//  notification's `filterCriteria` (NotificationScheduler.headsUpCriteria /
//  .sharedUpdateCriteria) — even when Timer isn't running. Written as "not one of the
//  muted kinds", so anything untagged (finish alerts, notifications scheduled before
//  this version) always comes through. AlarmKit alarms aren't notifications and are
//  never affected. Nothing is stored: iOS keeps the filter's values per Focus.
//

import AppIntents
import Foundation

struct TimerFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Timer"
    static var description: IntentDescription? = IntentDescription("Choose which Timer notifications stay quiet during this Focus. Alarms and “Time’s up” always come through.")

    @Parameter(title: "Heads-up reminders", default: false) var headsUpReminders: Bool
    @Parameter(title: "Shared-timer updates", default: false) var sharedTimerUpdates: Bool

    init() {}
    init(headsUpReminders: Bool, sharedTimerUpdates: Bool) {
        self.headsUpReminders = headsUpReminders
        self.sharedTimerUpdates = sharedTimerUpdates
    }

    var displayRepresentation: DisplayRepresentation {
        switch (headsUpReminders, sharedTimerUpdates) {
        case (false, false): DisplayRepresentation(title: "Only when a timer ends")
        case (true, true): DisplayRepresentation(title: "All Timer notifications")
        case (true, false): DisplayRepresentation(title: "Heads-up reminders, no shared-timer updates")
        case (false, true): DisplayRepresentation(title: "Shared-timer updates, no heads-up reminders")
        }
    }

    /// The kinds this Focus mutes.
    var mutedCriteria: [String] {
        (headsUpReminders ? [] : [NotificationScheduler.headsUpCriteria])
            + (sharedTimerUpdates ? [] : [NotificationScheduler.sharedUpdateCriteria])
    }

    var appContext: FocusFilterAppContext {
        let muted = mutedCriteria
        return FocusFilterAppContext(notificationFilterPredicate: muted.isEmpty ? nil : NSPredicate(format: "NOT (SELF IN %@)", muted))
    }

    /// The one-tap setup iOS can offer (it doesn't say which Focus): both kinds muted.
    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [TimerFocusFilter] {
        [suggestion]
    }
    static var suggestion: TimerFocusFilter { TimerFocusFilter(headsUpReminders: false, sharedTimerUpdates: false) }

    func perform() async throws -> some IntentResult { .result() }
}
