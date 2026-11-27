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

/// Overtime ends once the full-screen alarm was dismissed (`AlarmController.wasDismissed`).
struct DismissedAlarmTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyAnArmedFiredAndGoneAlarmCountsAsDismissed() {
        let fired = now.addingTimeInterval(-90)
        #expect(AlarmController.wasDismissed(armed: true, intendedEnd: fired, alarmListed: false, at: now))
        // Still ringing (listed as alerting) or restarted by Repeat (listed again).
        #expect(!AlarmController.wasDismissed(armed: true, intendedEnd: fired, alarmListed: true, at: now))
        // Never armed here, or the flag was cleared by a re-arm.
        #expect(!AlarmController.wasDismissed(armed: false, intendedEnd: fired, alarmListed: false, at: now))
        // Not due yet (cancelled early), or no record of when it was due.
        #expect(!AlarmController.wasDismissed(armed: true, intendedEnd: now.addingTimeInterval(30), alarmListed: false, at: now))
        #expect(!AlarmController.wasDismissed(armed: true, intendedEnd: nil, alarmListed: false, at: now))
    }
}

/// N3 for Siri / Shortcuts: `TimerIntentActions` `.shorten(minutes:)`.
struct RemoveTimeIntentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func siriTakesMinutesOffAndRefusesWhatItCannot() throws {
        let running = TimerPayload(id: "s", label: "Tea", endDate: now.addingTimeInterval(600), duration: 600)
        let shorter = try TimerIntentActions.updated(running, mutation: .shorten(minutes: 2), at: now)
        #expect(shorter.endDate == now.addingTimeInterval(480))
        #expect(shorter.updatedAt == now)
        #expect(TimerIntentActions.Mutation.shorten(minutes: 1).action == "shortened")
        // Too much: never to or past the end.
        #expect(throws: TimerIntentError.notEnoughTimeLeft) { try TimerIntentActions.updated(running, mutation: .shorten(minutes: 10), at: now) }
        // Not a positive, finite number.
        #expect(throws: TimerIntentError.nonPositiveMinutes) { try TimerIntentActions.updated(running, mutation: .shorten(minutes: 0), at: now) }
        #expect(throws: TimerIntentError.nonPositiveMinutes) { try TimerIntentActions.updated(running, mutation: .shorten(minutes: .infinity), at: now) }
        // A repeating countdown: it would ring twice.
        let daily = TimerPayload.composeAnnual(label: "Pills", targetDate: now.addingTimeInterval(3_600), timeZone: .gmt, frequency: .daily, at: now)
        #expect(throws: TimerIntentError.repeatingCountdown) { try TimerIntentActions.updated(daily, mutation: .shorten(minutes: 1), at: now) }
    }
}
