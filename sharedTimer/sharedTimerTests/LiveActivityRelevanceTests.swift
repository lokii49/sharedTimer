//
//  LiveActivityRelevanceTests.swift
//  sharedTimerTests
//
//  Which custom Live Activity the Dynamic Island shows when several quiet timers run:
//  `LiveActivityController.relevanceScore`.
//

import Foundation
import Testing
@testable import sharedTimer

struct LiveActivityRelevanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func running(endingIn seconds: TimeInterval) -> TimerPayload {
        TimerPayload(id: UUID().uuidString, label: "T", endDate: now.addingTimeInterval(seconds), duration: max(seconds, 60),
                     alarmEnabled: false, vibrationEnabled: false)
    }

    private func score(_ payload: TimerPayload, at date: Date? = nil) -> Double {
        LiveActivityController.relevanceScore(for: payload, at: date ?? now)
    }

    @Test func theTimerThatFinishesSoonestRanksFirst() {
        #expect(score(running(endingIn: 120)) > score(running(endingIn: 600)))
        #expect(score(running(endingIn: 600)) > score(running(endingIn: 86_400 * 30)))
    }

    @Test func scoresComputedAtDifferentMomentsStillCompare() {
        // A updated now (ends in 10 min); B updated 8 minutes later (ends in 5 min from
        // then = 13 min from now). A finishes first, so it must outrank B.
        let a = running(endingIn: 600), b = running(endingIn: 780)
        #expect(score(a) > score(b, at: now.addingTimeInterval(480)))
    }

    @Test func runningOutranksPausedOutranksFinished() {
        let farOff = running(endingIn: 86_400 * 365 * 10)   // past the minute range: bottom of running
        let pausedSoon = running(endingIn: 60).paused(at: now)
        let pausedLong = running(endingIn: 7_200).paused(at: now)
        let finished = running(endingIn: -30)
        #expect(score(farOff) > score(pausedSoon))
        #expect(score(pausedSoon) > score(pausedLong))
        #expect(score(pausedLong) > score(finished))
        #expect(score(finished) == 0)
    }

    @Test func aSequenceIsScoredByItsCurrentPhase() {
        var sequence = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 600)], loopCount: 1)
        sequence.endDate = now.addingTimeInterval(-10)   // phase 0 over; "Rest" runs until +590 s
        #expect(score(sequence) > 0)
        #expect(score(sequence) == score(running(endingIn: 590)))
    }
}
