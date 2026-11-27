//
//  FocusFilterTests.swift
//  sharedTimerTests
//
//  N10: what each Focus filter setting lets through. The predicate is evaluated by iOS
//  against a notification's `filterCriteria`; here it's evaluated the same way.
//

import AppIntents
import Foundation
import Testing
@testable import sharedTimer

struct FocusFilterTests {
    private func shows(_ filter: TimerFocusFilter, _ criteria: String?) -> Bool {
        guard let predicate = filter.appContext.notificationFilterPredicate else { return true }
        return predicate.evaluate(with: criteria)
    }

    @Test func theSuggestionMutesBothKindsButNeverAFinish() {
        let quiet = TimerFocusFilter.suggestion
        #expect(!shows(quiet, NotificationScheduler.headsUpCriteria))
        #expect(!shows(quiet, NotificationScheduler.sharedUpdateCriteria))
        // Untagged: finish alerts, and anything scheduled before this version.
        #expect(shows(quiet, nil))
        #expect(shows(quiet, "finish"))
    }

    @Test func eachSwitchLetsItsOwnKindThrough() {
        let keepUpdates = TimerFocusFilter(headsUpReminders: false, sharedTimerUpdates: true)
        #expect(!shows(keepUpdates, NotificationScheduler.headsUpCriteria))
        #expect(shows(keepUpdates, NotificationScheduler.sharedUpdateCriteria))
        let keepReminders = TimerFocusFilter(headsUpReminders: true, sharedTimerUpdates: false)
        #expect(shows(keepReminders, NotificationScheduler.headsUpCriteria))
        #expect(!shows(keepReminders, NotificationScheduler.sharedUpdateCriteria))
        // Both on: no filter at all.
        #expect(TimerFocusFilter(headsUpReminders: true, sharedTimerUpdates: true).appContext.notificationFilterPredicate == nil)
    }
}
