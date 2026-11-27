//
//  TimerStatsTests.swift
//  sharedTimerTests
//
//  N4: History stats — periods, time by name, streaks, CSV.
//

import Foundation
import Testing
@testable import sharedTimer

struct TimerStatsTests {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()
    // 2027-01-15 12:00 IST.
    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 4 * 86_400)

    private func run(_ label: String, minutes: Double, daysAgo: Double, kind: TimerKind = .timer) -> TimerHistoryEntry {
        var payload = TimerPayload(id: UUID().uuidString, label: label, endDate: now, duration: minutes * 60, kind: kind)
        payload.endDate = now.addingTimeInterval(-daysAgo * 86_400)
        return TimerHistoryEntry(payload, endedAt: payload.endDate)
    }

    @Test func periodsAreRollingAndAllIsEverything() {
        let entries = [run("Tea", minutes: 4, daysAgo: 1), run("Tea", minutes: 4, daysAgo: 10), run("Tea", minutes: 4, daysAgo: 40)]
        #expect(TimerStats.entries(entries, in: .week, now: now, calendar: calendar).count == 1)
        #expect(TimerStats.entries(entries, in: .month, now: now, calendar: calendar).count == 2)
        #expect(TimerStats.entries(entries, in: .all, now: now, calendar: calendar).count == 3)
    }

    @Test func timeByNameMergesCaseAndSkipsCountdowns() {
        let entries = [run("Pasta", minutes: 8, daysAgo: 0.1), run("pasta ", minutes: 10, daysAgo: 2),
                       run("Tea", minutes: 4, daysAgo: 1), run("Birthday", minutes: 60 * 24 * 30, daysAgo: 1, kind: .countdown)]
        let totals = TimerStats.totals(entries)
        #expect(totals.map(\.label) == ["Pasta", "Tea"])   // the most recent spelling
        #expect(totals[0].time == 18 * 60 && totals[0].runs == 2)
        #expect(TimerStats.totalTime(entries) == 22 * 60)
    }

    @Test func aStreakCountsDaysInARowEndingTodayOrYesterday() {
        let fasting = (1...5).map { run("16:8 fast", minutes: 960, daysAgo: Double($0)) }   // yesterday back 5 days
        let broken = [run("Tea", minutes: 4, daysAgo: 0.1), run("Tea", minutes: 4, daysAgo: 2)]   // gap yesterday
        let old = [run("Run", minutes: 30, daysAgo: 3), run("Run", minutes: 30, daysAgo: 4)]   // ended 3 days ago
        let streaks = TimerStats.streaks(fasting + broken + old, now: now, calendar: calendar)
        #expect(streaks == [TimerStats.Streak(label: "16:8 fast", days: 5)])
    }

    @Test func csvHasAHeaderOneRowPerRunAndEscapesNames() {
        let entries = [run("Tea, green", minutes: 4, daysAgo: 1), run("Say \"hi\"", minutes: 2.5, daysAgo: 2)]
        let lines = TimerStats.csv(entries).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0] == "Ended,Name,Type,Minutes,Repeats")
        #expect(lines[1].contains(",\"Say \"\"hi\"\"\",timer,2.5,"))   // oldest first
        #expect(lines[2].contains(",\"Tea, green\",timer,4.0,"))
    }
}
