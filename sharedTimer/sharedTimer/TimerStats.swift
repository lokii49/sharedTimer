//
//  TimerStats.swift
//  sharedTimer
//
//  N4 (owner's pick B, 2026-11-27, https://claude.ai/artifact/FDiXF7dkvss9bS31wtfbUQ):
//  totals, streaks and a CSV export from what TimerHistory already keeps on this
//  iPhone (90 days, 200 runs). Pure functions of the entries and a date, so the view
//  and the tests agree. Main app only.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, all
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .all: "All"
        }
    }

    /// Rolling, so "Week" always means the last 7 days, not since Monday.
    func start(before now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .day, value: -30, to: now)
        case .all: nil
        }
    }
}

enum TimerStats {
    struct LabelTotal: Equatable, Identifiable {
        let label: String
        let time: TimeInterval
        let runs: Int
        var id: String { label }
    }

    struct Streak: Equatable, Identifiable {
        let label: String
        let days: Int
        var id: String { label }
    }

    static func entries(_ all: [TimerHistoryEntry], in period: StatsPeriod, now: Date, calendar: Calendar = .current) -> [TimerHistoryEntry] {
        guard let start = period.start(before: now, calendar: calendar) else { return all.filter { $0.endedAt <= now } }
        return all.filter { $0.endedAt > start && $0.endedAt <= now }
    }

    /// Whether a run's length counts as time spent. A countdown's "length" is the wait
    /// until its date (weeks, a year), not something timed — it counts as a run only.
    static func isTimed(_ entry: TimerHistoryEntry) -> Bool {
        entry.sequence != nil || entry.kind == .timer
    }

    /// Time per label, most first; labels compared without case or surrounding spaces,
    /// shown as last used.
    static func totals(_ entries: [TimerHistoryEntry]) -> [LabelTotal] {
        var order: [String] = []
        var names: [String: String] = [:]
        var time: [String: TimeInterval] = [:]
        var runs: [String: Int] = [:]
        for entry in entries.sorted(by: { $0.endedAt > $1.endedAt }) where isTimed(entry) {
            let key = entry.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if names[key] == nil { names[key] = entry.label; order.append(key) }
            time[key, default: 0] += entry.length
            runs[key, default: 0] += 1
        }
        return order.map { LabelTotal(label: names[$0]!, time: time[$0]!, runs: runs[$0]!) }
            .sorted { $0.time != $1.time ? $0.time > $1.time : $0.label < $1.label }
    }

    /// The first `limit` totals, then everything else as one "Other" row.
    static func topWithOther(_ totals: [LabelTotal], limit: Int, otherLabel: String) -> [LabelTotal] {
        guard totals.count > limit else { return totals }
        let rest = totals.dropFirst(limit)
        return Array(totals.prefix(limit)) + [LabelTotal(label: otherLabel, time: rest.reduce(0) { $0 + $1.time }, runs: rest.reduce(0) { $0 + $1.runs })]
    }

    /// Set-for time per bar for the day chart: one bar per day for Week (7) and Month
    /// (30), one per week for All. Oldest first, empty days included (zero).
    static func bars(_ entries: [TimerHistoryEntry], in period: StatsPeriod, now: Date, calendar: Calendar = .current) -> [(start: Date, time: TimeInterval)] {
        let timed = entries.filter(isTimed)
        let today = calendar.startOfDay(for: now)
        let starts: [Date]
        let unit: Calendar.Component
        switch period {
        case .week, .month:
            let count = period == .week ? 7 : 30
            starts = (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
            unit = .day
        case .all:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let oldest = timed.map(\.endedAt).min() ?? now
            let firstWeek = calendar.dateInterval(of: .weekOfYear, for: oldest)?.start ?? thisWeek
            var week = firstWeek
            var list: [Date] = []
            while week <= thisWeek && list.count < 60 {
                list.append(week)
                week = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
            }
            starts = list
            unit = .weekOfYear
        }
        return starts.map { start in
            let end = calendar.date(byAdding: unit, value: 1, to: start)!
            return (start, timed.filter { $0.endedAt >= start && $0.endedAt < end && $0.endedAt <= now }.reduce(0) { $0 + $1.length })
        }
    }

    static func totalTime(_ entries: [TimerHistoryEntry]) -> TimeInterval {
        entries.filter(isTimed).reduce(0) { $0 + $1.length }
    }

    /// Days in a row, ending today or yesterday (a streak isn't broken until a whole day
    /// passes without one), with at least one run of that label. Only streaks of 2 days
    /// or more, longest first.
    static func streaks(_ entries: [TimerHistoryEntry], now: Date, calendar: Calendar = .current) -> [Streak] {
        var days: [String: Set<Date>] = [:]
        var names: [String: String] = [:]
        for entry in entries.sorted(by: { $0.endedAt > $1.endedAt }) where entry.endedAt <= now {
            let key = entry.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if names[key] == nil { names[key] = entry.label }
            days[key, default: []].insert(calendar.startOfDay(for: entry.endedAt))
        }
        let today = calendar.startOfDay(for: now)
        var result: [Streak] = []
        for (key, set) in days {
            guard var day = [today, calendar.date(byAdding: .day, value: -1, to: today)!].first(where: set.contains) else { continue }
            var count = 0
            while set.contains(day) {
                count += 1
                day = calendar.date(byAdding: .day, value: -1, to: day)!
            }
            if count >= 2 { result.append(Streak(label: names[key]!, days: count)) }
        }
        return result.sorted { $0.days != $1.days ? $0.days > $1.days : $0.label < $1.label }
    }

    /// One row per run, oldest first: when it ended (ISO 8601, UTC), its name, what it
    /// was, its length in minutes (extends included), and how it repeats.
    static func csv(_ entries: [TimerHistoryEntry]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ raw: String) -> String {
            // Names can come from other people's links: one starting = + - @ (or a tab
            // or return) would run as a formula in a spreadsheet, so it's prefixed with '.
            let text = raw.first.map { "=+-@\t\r".contains($0) } == true ? "'" + raw : raw
            return text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var lines = ["Ended,Name,Type,Minutes,Repeats"]
        for entry in entries.sorted(by: { $0.endedAt < $1.endedAt }) {
            let type = entry.sequence != nil ? "sequence" : entry.kind.rawValue
            let repeats = entry.frequency?.rawValue ?? (entry.yearly ? "yearly" : "")
            let minutes = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), entry.length / 60)
            lines.append([iso.string(from: entry.endedAt), field(entry.label), type, minutes, repeats].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

/// The CSV handed to the share sheet.
struct HistoryCSV: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName("Timer history.csv")
    }
}
