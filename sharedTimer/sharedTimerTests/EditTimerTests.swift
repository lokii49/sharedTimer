//
//  EditTimerTests.swift
//  sharedTimerTests
//

import Foundation
import Testing
@testable import sharedTimer

struct EditTimerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func renameTrimsKeepsLabelWhenEmptyAndStampsUpdate() {
        let now = date("2026-10-07T12:00:00Z")
        let timer = TimerPayload(id: "t", label: "Pasta", endDate: now.addingTimeInterval(300), duration: 600, updatedAt: now.addingTimeInterval(-60))

        let renamed = timer.edited(label: "  Rice \n", alarmEnabled: false, vibrationEnabled: true, at: now)
        #expect(renamed.label == "Rice")
        #expect(renamed.alarmEnabled == false)
        #expect(renamed.vibrationEnabled == true)
        #expect(renamed.updatedAt == now)
        #expect(renamed.endDate == timer.endDate)
        #expect(renamed.duration == timer.duration)
        #expect(timer.shouldAdopt(renamed))

        #expect(timer.edited(label: "   ", alarmEnabled: true, vibrationEnabled: true, at: now).label == "Pasta")
    }

    @Test func timerIgnoresTargetDateAndPausedTimerStaysPaused() {
        let now = date("2026-10-07T12:00:00Z")
        let timer = TimerPayload(id: "t", label: "Tea", endDate: now.addingTimeInterval(120), duration: 180)
        let moved = timer.edited(label: "Tea", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(9_000), at: now)
        #expect(moved.endDate == timer.endDate)

        let paused = timer.paused(at: now).edited(label: "Green tea", alarmEnabled: true, vibrationEnabled: false, at: now)
        #expect(paused.pausedRemaining == 120)
        #expect(paused.label == "Green tea")
    }

    @Test func sequencesAreNeverEdited() {
        let sequence = TimerPayload.composeSequence(label: "Work", phases: [SequencePhase(label: "Work", duration: 60)], loopCount: 2)
        let edited = sequence.edited(label: "Renamed", alarmEnabled: false, vibrationEnabled: false)
        #expect(edited.label == "Work")
        #expect(edited.alarmEnabled == sequence.alarmEnabled)
        #expect(edited.updatedAt == sequence.updatedAt)
    }

    @Test func countdownTargetKeepsOriginalStart() {
        let now = date("2026-10-07T12:00:00Z")
        let start = now.addingTimeInterval(-3_600)
        let countdown = TimerPayload(id: "c", label: "Trip", endDate: start.addingTimeInterval(7_200), duration: 7_200, kind: .countdown)

        let later = countdown.edited(label: "Trip", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(86_400), at: now)
        #expect(later.endDate == now.addingTimeInterval(86_400))
        #expect(later.duration == 86_400 + 3_600)
        #expect(later.endDate.addingTimeInterval(-later.duration) == start)
        // Duration changed, so a recipient's extend banner (pure-extend diff) stays quiet.
        #expect(later.duration != countdown.duration)

        let sooner = countdown.edited(label: "Trip", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(600), at: now)
        #expect(sooner.duration == 600 + 3_600)
        #expect(abs(sooner.progress(at: now) - 600.0 / 4_200.0) < 0.0001)
    }

    @Test func countdownPastTargetFinishesAndPausedIgnoresDate() {
        let now = date("2026-10-07T12:00:00Z")
        let countdown = TimerPayload(id: "c", label: "Trip", endDate: now.addingTimeInterval(600), duration: 1_200, kind: .countdown)

        let past = countdown.edited(label: "Trip", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(-600), at: now)
        #expect(past.endDate == now)
        #expect(past.duration >= 1)

        let paused = countdown.paused(at: now)
        let pausedEdit = paused.edited(label: "Trip", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(86_400), at: now)
        #expect(pausedEdit.endDate == paused.endDate)
        #expect(pausedEdit.pausedRemaining == paused.pausedRemaining)
    }

    @Test func finishedCountdownMovedForwardRunsAgain() {
        let now = date("2026-10-07T12:00:00Z")
        let finished = TimerPayload(id: "c", label: "Launch", endDate: now.addingTimeInterval(-60), duration: 600, kind: .countdown)
        let revived = finished.edited(label: "Launch", alarmEnabled: true, vibrationEnabled: true, targetDate: now.addingTimeInterval(3_600), at: now)
        #expect(revived.endDate > now)
        #expect(revived.endDate.addingTimeInterval(-revived.duration) == now.addingTimeInterval(-660))
    }

    @Test func annualTargetReanchorsInItsOwnTimeZone() throws {
        let now = date("2026-10-07T12:00:00Z")
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let birthday = TimerPayload.composeAnnual(label: "Mum", targetDate: date("2027-03-01T00:00:00Z"), timeZone: tokyo, at: now)

        let moved = birthday.edited(label: "Mum", alarmEnabled: true, vibrationEnabled: true, targetDate: date("2027-05-10T01:00:00Z"), at: now)
        let rule = try #require(moved.recurrence)
        #expect(rule.timeZoneID == "Asia/Tokyo")
        #expect(rule.month == 5 && rule.day == 10 && rule.hour == 10)
        #expect(moved.endDate == date("2027-05-10T01:00:00Z"))

        // A past date picks the next anniversary instead of finishing.
        let past = birthday.edited(label: "Mum", alarmEnabled: true, vibrationEnabled: true, targetDate: date("2026-01-15T03:00:00Z"), at: now)
        #expect(past.endDate == date("2027-01-15T03:00:00Z"))
    }

    @Test func renamingClampedLeapDayKeepsAnchor() throws {
        // Anchored Feb 29; in 2027 the occurrence is clamped to Feb 28. A rename passes
        // that clamped endDate back as the target — it must not re-anchor to the 28th.
        let now = date("2026-10-07T12:00:00Z")
        let leap = TimerPayload.composeAnnual(label: "Leap", targetDate: date("2028-02-29T09:00:00Z"), timeZone: .gmt, at: now)
        let clamped = leap.advancedSequence(at: date("2028-03-01T00:00:00Z"))
        #expect(clamped.endDate == date("2029-02-28T09:00:00Z"))

        let renamed = clamped.edited(label: "Leap day", alarmEnabled: true, vibrationEnabled: true, targetDate: clamped.endDate, at: date("2028-03-01T00:00:00Z"))
        #expect(renamed.recurrence?.day == 29)
        #expect(renamed.endDate == clamped.endDate)
    }

    @Test func editRoundTripsThroughLinkAndWinsOverOlderCopy() throws {
        let now = Date()
        let original = TimerPayload(id: "c", label: "Party", endDate: now.addingTimeInterval(3_600), duration: 3_600, kind: .countdown, updatedAt: now.addingTimeInterval(-10))
        let edited = original.edited(label: "Party 🎉", alarmEnabled: false, vibrationEnabled: false, targetDate: now.addingTimeInterval(7_200), at: now)
        let decoded = try #require(TimerPayload.from(url: edited.url()))
        #expect(decoded.label == "Party 🎉")
        #expect(decoded.alarmEnabled == false)
        #expect(decoded.vibrationEnabled == false)
        #expect(abs(decoded.endDate.timeIntervalSince(edited.endDate)) < 1)
        #expect(original.shouldAdopt(decoded))
        #expect(!decoded.shouldAdopt(original))
    }
}
