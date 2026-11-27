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

    @Test func barsBeyondEightAddUpAsOther() {
        let totals = (1...10).map { TimerStats.LabelTotal(label: "T\($0)", time: TimeInterval(100 - $0), runs: 1) }
        let shown = TimerStats.topWithOther(totals, limit: 8, otherLabel: "Other")
        #expect(shown.count == 9 && shown.last?.label == "Other")
        #expect(shown.reduce(0) { $0 + $1.time } == totals.reduce(0) { $0 + $1.time })
        #expect(TimerStats.topWithOther(Array(totals.prefix(8)), limit: 8, otherLabel: "Other").count == 8)
    }

    @Test func csvNeverStartsAFieldWithAFormula() {
        let csv = TimerStats.csv([run("=HYPERLINK(\"x\")", minutes: 1, daysAgo: 1), run("+1", minutes: 1, daysAgo: 2), run("@a", minutes: 1, daysAgo: 3)])
        #expect(csv.contains(",\"'=HYPERLINK(\"\"x\"\")\",timer,"))
        #expect(csv.contains(",'+1,timer,"))
        #expect(csv.contains(",'@a,timer,"))
    }
}

extension TimerStatsTests {
    @Test func groupsSplitByLengthAndDay() {
        let entries = [run("Pasta", minutes: 8, daysAgo: 0.1), run("pasta", minutes: 8, daysAgo: 0.2), run("Pasta", minutes: 10, daysAgo: 0.15),
                       run("Pasta", minutes: 8, daysAgo: 1.1)]
        let days = TimerHistory.grouped(entries, calendar: calendar)
        #expect(days.count == 2)
        #expect(days[0].groups.map(\.entries.count).sorted() == [1, 2])   // 8 m ×2 and 10 m apart
        #expect(days[1].groups.count == 1)
    }

    @Test func dayBarsCoverEveryDayAndOnlyTimedRuns() {
        let entries = [run("Tea", minutes: 4, daysAgo: 0.1), run("Tea", minutes: 6, daysAgo: 2.1),
                       run("Birthday", minutes: 60 * 24 * 10, daysAgo: 1, kind: .countdown)]
        let week = TimerStats.bars(entries, in: .week, now: now, calendar: calendar)
        #expect(week.count == 7)
        #expect(abs((week.last?.time ?? 0) - 240) < 0.001)
        #expect(abs(week.reduce(0) { $0 + $1.time } - 600) < 0.001)   // the countdown isn't timed
        #expect(TimerStats.bars(entries, in: .month, now: now, calendar: calendar).count == 30)
    }

    @Test func dataStartShowsOnlyWhenHistoryIsFull() {
        let some = (0..<10).map { run("Tea", minutes: 4, daysAgo: Double($0)) }
        #expect(TimerHistory.dataStart(some) == nil)
        let full = (0..<TimerHistory.limit).map { run("Tea", minutes: 4, daysAgo: Double($0) * 0.4) }
        #expect(TimerHistory.dataStart(full) == full.map(\.endedAt).min())
    }
}
