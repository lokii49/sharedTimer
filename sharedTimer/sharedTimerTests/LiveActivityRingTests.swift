//
//  LiveActivityRingTests.swift
//  sharedTimerTests
//
//  The narrow (iOS 27, landscape) Dynamic Island shows a draining ring instead of
//  digits; the custom card carries the run length (`span`) it needs.
//

import Foundation
import Testing
@testable import sharedTimer

struct LiveActivityRingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theRingStartsWhenTheRunStartedIncludingExtends() {
        let state = TimerActivityAttributes.ContentState(endDate: now.addingTimeInterval(600), pausedRemaining: nil, span: 900)
        #expect(state.ringStart == now.addingTimeInterval(-300))
        // An older build's card has no span: no ring (the slot keeps its digits).
        #expect(TimerActivityAttributes.ContentState(endDate: now, pausedRemaining: nil).ringStart == nil)
    }

    @Test func theNextQuietPhaseGetsItsOwnLength() {
        let upcoming = [TimerActivityAttributes.Phase(label: "Rest", kind: .timer, endDate: now.addingTimeInterval(300)),
                        TimerActivityAttributes.Phase(label: "Work", kind: .timer, endDate: now.addingTimeInterval(1_800))]
        let state = TimerActivityAttributes.ContentState(endDate: now, pausedRemaining: nil, upcoming: upcoming, span: 1_500)
        let rest = state.current(at: now.addingTimeInterval(10))
        #expect(rest.label == "Rest" && rest.span == 300 && rest.ringStart == now)
        let work = state.current(at: now.addingTimeInterval(400))
        #expect(work.label == "Work" && work.span == 1_500 && work.ringStart == now.addingTimeInterval(300))
    }
}
