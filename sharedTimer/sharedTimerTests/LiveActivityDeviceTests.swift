//
//  LiveActivityDeviceTests.swift
//  sharedTimerTests
//
//  The custom (both toggles off) Live Activity against real ActivityKit — needs no
//  AlarmKit permission, only Live Activities enabled, so it runs on a physical device
//  and is skipped where activities are unavailable. Each test ends its own card.
//

import ActivityKit
import Foundation
import Testing
@testable import sharedTimer

@Suite(.serialized, .enabled(if: ActivityAuthorizationInfo().areActivitiesEnabled))
struct LiveActivityDeviceTests {
    private func cards(_ id: String) -> [Activity<TimerActivityAttributes>] {
        Activity<TimerActivityAttributes>.activities.filter { $0.attributes.timerID == id }
    }

    /// Arming a timer again after its card's end (a widget Repeat, a quiet sequence's
    /// next phase) must reuse that card, not add a second one. Reuse accepts `.stale`
    /// too — on the iPhone 14 Pro (2026-11-13) a foreground app's card still read
    /// `.active` 15 s past its `staleDate`, so whether the system ever reports `.stale`
    /// here is unconfirmed; this checks the outcome either way.
    @Test func cardPastItsEndIsReusedInsteadOfDoubled() async {
        let quiet = TimerPayload(label: "Stale card test", duration: 2, alarmEnabled: false, vibrationEnabled: false)
        await LiveActivityController.startAwaiting(for: quiet)
        #expect(cards(quiet.id).count == 1)
        try? await Task.sleep(for: .seconds(4))

        await LiveActivityController.startAwaiting(for: quiet.repeated())
        #expect(cards(quiet.id).count == 1)
        #expect(cards(quiet.id).first?.activityState == .active)

        await LiveActivityController.endAwaiting(id: quiet.id)
    }
}
