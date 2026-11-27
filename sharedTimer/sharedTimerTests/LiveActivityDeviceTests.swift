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
        // The update's new stale date brings the card back to `.active`, but ActivityKit
        // reports that a moment later (a CI simulator read `.stale` right after it).
        var state = cards(quiet.id).first?.activityState
        for _ in 0..<30 where state != .active {
            try? await Task.sleep(for: .milliseconds(100))
            state = cards(quiet.id).first?.activityState
        }
        #expect(state == .active)

        await LiveActivityController.endAwaiting(id: quiet.id)
    }

    /// With several quiet cards up, the soonest finish carries the highest score and a
    /// paused card the lowest — read back from ActivityKit itself.
    @Test func soonestRunningCardCarriesTheHighestRelevance() async {
        let soon = TimerPayload(label: "Relevance soon", duration: 120, alarmEnabled: false, vibrationEnabled: false)
        let later = TimerPayload(label: "Relevance later", duration: 600, alarmEnabled: false, vibrationEnabled: false)
        let paused = TimerPayload(label: "Relevance paused", duration: 60, alarmEnabled: false, vibrationEnabled: false).paused()
        for payload in [later, paused, soon] { await LiveActivityController.startAwaiting(for: payload) }
        // Read without throwing, so the cards are always ended (awaited) below.
        let scores = [soon, later, paused].map { cards($0.id).first?.content.relevanceScore ?? -1 }
        print("LA_RELEVANCE soon=\(scores[0]) later=\(scores[1]) paused=\(scores[2])")
        #expect(scores[0] > scores[1])
        #expect(scores[1] > scores[2])
        for payload in [soon, later, paused] { await LiveActivityController.endAwaiting(id: payload.id) }
    }
}
