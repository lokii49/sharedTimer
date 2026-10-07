//
//  RecentTimersStore.swift
//  Shared
//
//  The last few distinct plain timers the user started (label + length + toggles),
//  most recent first — the one-tap "Recent" chips in the New Timer sheet, the
//  home-screen long-press Quick Actions, and the Control Center / Action button control
//  ("Start Pasta 8m"). Timers only: a countdown targets a date, which can't be re-run
//  as-is, and sequences have their own saved-sequence list.
//
//  Compiled by sharedTimer (records, edits) and sharedTimerWidget (the control reads
//  its title); excluded from Clip/Messages in the project's Shared exception sets.
//  App Group backed so both processes see the same list.
//

import Foundation

struct RecentTimer: Codable, Hashable, Identifiable {
    var label: String
    var duration: TimeInterval
    var alarmEnabled: Bool
    var vibrationEnabled: Bool

    /// Same label + length = same recent, whatever the toggles were.
    var id: String { "\(label)|\(Int(duration))" }

    /// "Pasta 8m", "Laundry 1h 30m", "Plank 45s".
    var title: String { "\(label) \(RecentTimer.lengthText(duration))" }

    static func lengthText(_ duration: TimeInterval) -> String {
        let total = max(1, Int(duration.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    init(label: String, duration: TimeInterval, alarmEnabled: Bool, vibrationEnabled: Bool) {
        self.label = label
        self.duration = duration
        self.alarmEnabled = alarmEnabled
        self.vibrationEnabled = vibrationEnabled
    }

    /// Hand-written and lenient on purpose (see CLAUDE.md's SavedSequenceStore warning):
    /// this list is decoded as a root array, so one strict field added later without a
    /// default would make every decode fail and silently empty everyone's recents.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        alarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        vibrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .vibrationEnabled) ?? false
    }

    /// A fresh payload for this recent, running from now.
    func payload() -> TimerPayload {
        TimerPayload.compose(label: label, kind: .timer, minutes: duration / 60, targetDate: Date(), alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }
}

enum RecentTimersStore {
    static let limit = 6
    private static let key = "recentTimers"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.lokesh.sharedTimer")
    }

    static func all() -> [RecentTimer] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentTimer].self, from: data)) ?? []
    }

    /// Moves (or adds) this timer to the front. Ignores countdowns and sequences.
    static func record(_ payload: TimerPayload) {
        guard payload.kind == .timer, payload.sequence == nil else { return }
        let recent = RecentTimer(label: payload.label, duration: payload.duration, alarmEnabled: payload.alarmEnabled, vibrationEnabled: payload.vibrationEnabled)
        var list = all().filter { $0.id != recent.id }
        list.insert(recent, at: 0)
        save(Array(list.prefix(limit)))
    }

    static func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    private static func save(_ list: [RecentTimer]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults?.set(data, forKey: key)
    }
}
