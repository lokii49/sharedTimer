//
//  RecentTimersStore.swift
//  Shared
//
//  The last few distinct plain timers the user started (label + length + toggles),
//  most recent first — the one-tap "Recent" chips in the New Timer sheet, the
//  home-screen long-press Quick Actions, and the Control Center / Action button control
//  ("Start Pasta 8m"). Timers and sequences (1.0.7, mockup D5 · A: one recency list,
//  sequences marked with a glyph); never countdowns, which target a date and can't be
//  re-run as-is. A sequence recent carries its blueprint (phases + loops), so the
//  widget can show it and the app can start it without the main-app-only
//  SavedSequenceStore.
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
    /// A sequence's blueprint (at phase 0, loop 0); nil for a plain timer. `duration`
    /// is then the whole run (every phase, every loop), for the length text.
    var sequence: SequenceInfo?

    /// Same label + length = same recent, whatever the toggles were.
    var id: String {
        guard let sequence else { return "\(label)|\(Int(duration))" }
        return "seq|\(label)|\(sequence.phases.count)|\(sequence.loopCount)|\(Int(duration))"
    }

    var isSequence: Bool { sequence != nil }

    /// SF Symbol for chips and Quick Actions.
    var symbolName: String { isSequence ? "arrow.triangle.2.circlepath" : "timer" }

    /// "Pasta 8m", "Laundry 1h 30m", "Plank 45s".
    var title: String { "\(label) \(RecentTimer.lengthText(duration))" }

    static func lengthText(_ duration: TimeInterval) -> String {
        let total = max(1, Int(duration.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? String(localized: "\(h)h \(m)m", comment: "Compact hours and minutes") : String(localized: "\(h)h", comment: "Compact hours") }
        if m > 0 { return s > 0 ? String(localized: "\(m)m \(s)s", comment: "Compact minutes and seconds") : String(localized: "\(m)m", comment: "Compact minutes") }
        return String(localized: "\(s)s", comment: "Compact seconds")
    }

    init(label: String, duration: TimeInterval, alarmEnabled: Bool, vibrationEnabled: Bool, sequence: SequenceInfo? = nil) {
        self.label = label
        self.duration = duration
        self.alarmEnabled = alarmEnabled
        self.vibrationEnabled = vibrationEnabled
        self.sequence = sequence
    }

    /// A sequence recent, named as it was started or saved.
    init(sequence: SequenceInfo, name: String) {
        let blueprint = SequenceInfo(phases: sequence.phases, loopCount: max(1, sequence.loopCount), phaseIndex: 0, loopIndex: 0)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(label: trimmed.isEmpty ? (sequence.phases.first?.label ?? String(localized: "Sequence")) : trimmed,
                  duration: blueprint.phases.reduce(0) { $0 + $1.duration } * Double(blueprint.loopCount),
                  alarmEnabled: blueprint.phases.first?.alarmEnabled ?? true,
                  vibrationEnabled: blueprint.phases.first?.vibrationEnabled ?? false,
                  sequence: blueprint)
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
        // `try?`: one sequence this build can't read must not drop the whole list.
        sequence = (try? c.decodeIfPresent(SequenceInfo.self, forKey: .sequence)) ?? nil
    }

    /// A fresh payload for this recent, running from now.
    func payload() -> TimerPayload {
        if let sequence, !sequence.phases.isEmpty {
            return TimerPayload.composeSequence(phases: sequence.phases, loopCount: sequence.loopCount)
        }
        return TimerPayload.compose(label: label, kind: .timer, minutes: duration / 60, targetDate: Date(), alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
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

    /// Moves (or adds) this timer to the front. Ignores countdowns and sequences (a
    /// sequence's name isn't on the payload — see `record(sequence:name:)`).
    static func record(_ payload: TimerPayload) {
        guard payload.kind == .timer, payload.sequence == nil else { return }
        record(RecentTimer(label: payload.label, duration: payload.duration, alarmEnabled: payload.alarmEnabled, vibrationEnabled: payload.vibrationEnabled))
    }

    /// A sequence started from New Sequence or saved as a template.
    static func record(sequence: SequenceInfo, name: String) {
        guard !sequence.phases.isEmpty else { return }
        record(RecentTimer(sequence: sequence, name: name))
    }

    /// Moves (or adds) this recent to the front — also how starting one from a chip,
    /// Quick Action or the Control marks it most recent.
    static func record(_ recent: RecentTimer) {
        lock.withLock {
            var list = all().filter { $0.id != recent.id }
            list.insert(recent, at: 0)
            save(Array(list.prefix(limit)))
        }
    }

    /// Read-modify-write guard: a Control Center start (`startRecent`, off the main
    /// thread) and a start in the app could otherwise drop one of the two. Writers all
    /// run in the app's process — the widget only reads — so an in-process lock does.
    private static let lock = NSLock()

    private static let seededKey = "recentTimersSeeded"

    /// One-time backfill from the timers already in the store, so the first build with
    /// recents doesn't start with an empty list (found on device: the only "recent" was
    /// the Control's 5-minute default, while the user's own timers weren't listed).
    /// Most recently started first. Flagged once, so clearing the chips later doesn't
    /// bring them back.
    static func seedIfNeeded(from payloads: [TimerPayload]) {
        guard defaults?.bool(forKey: seededKey) != true else { return }
        defaults?.set(true, forKey: seededKey)
        let started = payloads
            .filter { $0.kind == .timer && $0.sequence == nil }
            .sorted { $0.endDate.addingTimeInterval(-$0.span) < $1.endDate.addingTimeInterval(-$1.span) }
        for payload in started {
            record(payload)  // oldest first, so the newest ends up at the front
        }
    }

    static func remove(id: String) {
        lock.withLock { save(all().filter { $0.id != id }) }
    }

    private static func save(_ list: [RecentTimer]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults?.set(data, forKey: key)
    }
}
