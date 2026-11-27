//
//  MessagesParityTests.swift
//  sharedTimerTests
//
//  Messages parity (owner's picks 1A–5A, 2026-11-27): the pure rules the Messages
//  extension shares with the app. Messages itself has no test target, so every decision
//  it makes lives in a Shared function tested here.
//

import Foundation
import Testing
@testable import sharedTimer

struct MessagesParityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: 1A Repeat when composing

    @Test func aRepeatingCountdownCanStartFromAPastDateButAOneOffCannot() {
        let past = now.addingTimeInterval(-3600)
        #expect(!ComposeRules.canStart(kind: .countdown, minutes: 5, targetDate: past, repeatFrequency: nil, at: now))
        #expect(ComposeRules.canStart(kind: .countdown, minutes: 5, targetDate: past, repeatFrequency: .weekly, at: now))
        #expect(!ComposeRules.canStart(kind: .timer, minutes: 0, targetDate: past, repeatFrequency: .weekly, at: now))
        #expect(ComposeRules.canStart(kind: .timer, minutes: 1, targetDate: past, repeatFrequency: nil, at: now))
    }

    @Test func theRepeatAppliesOnlyToACountdown() throws {
        let target = Date().addingTimeInterval(3 * 86400)
        let weekly = ComposeRules.payload(label: "  ", kind: .countdown, minutes: 5, targetDate: target, repeatFrequency: .weekly,
                                          alarmEnabled: true, vibrationEnabled: false)
        #expect(weekly.recurrence?.frequency == .weekly)
        #expect(weekly.label == String(localized: "Countdown"))
        #expect(!weekly.vibrationEnabled)
        // The Type picker went back to Timer with a repeat still chosen: a plain timer.
        let timer = ComposeRules.payload(label: "", kind: .timer, minutes: 4, targetDate: target, repeatFrequency: .weekly,
                                         alarmEnabled: true, vibrationEnabled: true)
        #expect(timer.recurrence == nil)
        #expect(timer.kind == .timer)
        #expect(timer.duration == 240)
        #expect(timer.label == String(localized: "Timer"))
        // And it survives the share link like one composed in the app.
        let decoded = try #require(TimerPayload.from(url: weekly.url()))
        #expect(decoded.recurrence?.frequency == .weekly)
    }
}
