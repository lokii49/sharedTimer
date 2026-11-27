//
//  RemoveTimeTests.swift
//  sharedTimerTests
//
//  N3 Remove time: `TimerPayload.shortened(by:at:)` / `canShorten(by:at:)`.
//

import Foundation
import Testing
@testable import sharedTimer

struct RemoveTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func running(left: TimeInterval, duration: TimeInterval = 600) -> TimerPayload {
        TimerPayload(id: "t", label: "Pasta", endDate: now.addingTimeInterval(left), duration: duration)
    }

    @Test func aMinuteComesOffARunningTimer() throws {
        let shorter = try #require(running(left: 300).shortened(by: 60, at: now))
        #expect(shorter.endDate == now.addingTimeInterval(240))
        #expect(shorter.updatedAt != nil)
    }

    @Test func aMinuteComesOffAPausedTimer() throws {
        let paused = running(left: 300).paused(at: now)
        let shorter = try #require(paused.shortened(by: 60, at: now))
        #expect(shorter.pausedRemaining == 240)
        #expect(shorter.isPaused)
    }

    @Test func neverToOrPastTheEnd() {
        #expect(running(left: 60).shortened(by: 60, at: now) == nil)
        #expect(running(left: 30).shortened(by: 60, at: now) == nil)
        #expect(running(left: 300).shortened(by: 600, at: now) == nil)
        #expect(running(left: 300).paused(at: now).shortened(by: 300, at: now) == nil)
        #expect(running(left: -5).shortened(by: 60, at: now) == nil)
        #expect(running(left: 300).shortened(by: 0, at: now) == nil)
    }

    @Test func extendsAreEatenFirst() throws {
        let extended = running(left: 300).extended(by: 120)
        #expect(extended.extraTime == 120)
        let shorter = try #require(extended.shortened(by: 60, at: now))
        #expect(shorter.extraTime == 60)
        let shortest = try #require(shorter.shortened(by: 300, at: now))
        #expect(shortest.extraTime == 0)
    }

    @Test func aPendingSequenceCannotBeShortened() {
        let pending = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 600)], loopCount: 1,
                                                   startDate: now.addingTimeInterval(3_600))
        #expect(!pending.canShorten(by: 60, at: now))
    }
}

extension RemoveTimeTests {
    /// Taking time off a repeating countdown would end the occurrence before its rule
    /// time; once that passes, the next rule date is the same occurrence again — it
    /// would ring twice. So "−" isn't offered there.
    @Test func aRepeatingCountdownOffersNoRemoveTime() throws {
        let target = Date(timeIntervalSince1970: 1_800_000_000 + 3_600)
        for frequency in [AnnualRecurrence.Frequency.daily, .weekly, .yearly] {
            let countdown = TimerPayload.composeAnnual(label: "Gym", targetDate: target, timeZone: .gmt, frequency: frequency,
                                                       at: Date(timeIntervalSince1970: 1_800_000_000))
            // What would happen: shortened by 1 minute, then just after that end…
            let shorter = countdown.extended(by: -60)
            let after = shorter.advancedRecurrence(at: shorter.endDate.addingTimeInterval(1))
            #expect(abs(after.endDate.timeIntervalSince(countdown.endDate)) < 1, "\(frequency): the same occurrence comes back")
            // …so it's not offered.
            #expect(!countdown.canShorten(by: 60, at: Date(timeIntervalSince1970: 1_800_000_000)))
        }
    }
}
