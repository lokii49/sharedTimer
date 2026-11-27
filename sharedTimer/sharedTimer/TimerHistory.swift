//
//  TimerHistory.swift
//  sharedTimer
//
//  On-device log of finished runs (1.0.7, D9): label, kind, length (extends included),
//  when it ended, and enough to run a timer or sequence again. Never on the wire, in
//  CloudKit or anywhere off this iPhone. Kept for `retention` (90 days), at most
//  `limit` (200) entries. Deleting a timer does not delete its history — that's the
//  point.
//
//  Recording doesn't hook any one mutation path. It scans the store after every
//  `TimerStore` write (chained onto `TimerStore.didPersist`, which Spotlight also
//  uses — the callback only schedules work) and when the app comes to the front. A
//  run is recorded once it's over: a plain timer/countdown when finished, a sequence
//  when exhausted (never per phase), a yearly countdown once per occurrence. It also
//  remembers the last copy it saw of each timer, so a run that finished and was then
//  repeated, extended past its end or deleted before a scan saw it finished is still
//  recorded. Entries are keyed by timer id + end second, so CloudKit echoes and
//  repeated scans never duplicate one.
//
//  Main app only.
//

import Foundation
import SwiftUI

struct TimerHistoryEntry: Codable, Hashable, Identifiable {
    var timerID: String
    var label: String
    var kind: TimerKind
    /// The run's length, extends included (`TimerPayload.span`).
    var length: TimeInterval
    /// The length it was started with — what "Run again" uses.
    var duration: TimeInterval
    var endedAt: Date
    var alarmEnabled: Bool
    var vibrationEnabled: Bool
    /// Blueprint for running a sequence again (phase 0, loop 0); nil otherwise.
    var sequence: SequenceInfo?
    var yearly: Bool
    /// How a repeating countdown repeats (1.0.8); nil for entries logged before, which
    /// were all yearly when `yearly` is set. `yearly` stays for older readers.
    var frequency: AnnualRecurrence.Frequency?

    var id: String { "\(timerID)|\(Int(endedAt.timeIntervalSince1970.rounded()))" }

    /// Timers and sequences can run again; a countdown's date has passed.
    var canRunAgain: Bool { sequence != nil || kind == .timer }

    init(_ payload: TimerPayload, endedAt: Date) {
        timerID = payload.id
        label = payload.label
        kind = payload.kind
        if let sequence = payload.sequence {
            let oneLoop = sequence.phases.reduce(0.0) { $0 + $1.duration }
            length = oneLoop * Double(sequence.loopCount)
        } else {
            length = payload.span
        }
        duration = payload.duration
        self.endedAt = endedAt
        alarmEnabled = payload.alarmEnabled
        vibrationEnabled = payload.vibrationEnabled
        sequence = payload.sequence.map { SequenceInfo(phases: $0.phases, loopCount: $0.loopCount, phaseIndex: 0, loopIndex: 0) }
        yearly = payload.recurrence != nil
        frequency = payload.recurrence?.frequency
    }

    /// Lenient, like RecentTimer: the log is decoded as a root array, so a field added
    /// later must never make every entry fail.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timerID = try c.decode(String.self, forKey: .timerID)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        kind = (try? c.decodeIfPresent(TimerKind.self, forKey: .kind)) ?? .timer
        length = try c.decodeIfPresent(TimeInterval.self, forKey: .length) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? length
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        alarmEnabled = try c.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        vibrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .vibrationEnabled) ?? false
        sequence = (try? c.decodeIfPresent(SequenceInfo.self, forKey: .sequence)) ?? nil
        yearly = try c.decodeIfPresent(Bool.self, forKey: .yearly) ?? false
        frequency = (try? c.decodeIfPresent(AnnualRecurrence.Frequency.self, forKey: .frequency)) ?? nil
    }

    /// The tag a repeating countdown's entry shows ("Daily" … "Yearly"), nil otherwise.
    var repeatTag: LocalizedStringKey? {
        guard yearly else { return nil }
        switch frequency ?? .yearly {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// A fresh payload for "Run again".
    func runAgainPayload() -> TimerPayload? {
        if let sequence, !sequence.phases.isEmpty {
            return TimerPayload.composeSequence(phases: sequence.phases, loopCount: sequence.loopCount)
        }
        guard kind == .timer else { return nil }
        return TimerPayload.compose(label: label, kind: .timer, minutes: duration / 60, targetDate: Date(),
                                    alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }
}

enum TimerHistory {
    static let limit = 200
    static let retention: TimeInterval = 90 * 86_400
    private static let key = "timerHistory"
    private static let defaults = UserDefaults(suiteName: "group.com.lokesh.sharedTimer")
    private static let lock = NSLock()

    /// Last copy seen of each stored timer (process-local), for runs that ended and
    /// then moved or vanished between scans.
    nonisolated(unsafe) private static var lastSeen: [String: TimerPayload] = [:]

    // MARK: Pure core (unit-tested)

    /// The runs in `stored` (plus ones `lastSeen` shows ended before they moved or
    /// were deleted) that are over at `now`.
    static func endedRuns(stored: [TimerPayload], lastSeen: [String: TimerPayload], now: Date) -> [TimerHistoryEntry] {
        var runs: [TimerHistoryEntry] = []
        let storedIDs = Set(stored.map(\.id))
        for payload in stored {
            if let run = endedRun(payload, now: now) { runs.append(run) }
            // Ended, then repeated/extended/resumed before a scan saw it finished
            // (`merged` drops it if it's the same run as above) — but only if that
            // change came after the old run's end. A pause or extend made *before* it
            // (saved by Messages or the notification service, which never trigger a
            // scan here) means the old copy never actually finished.
            // A repeating countdown the clock moved on to a later occurrence keeps its old
            // `updatedAt` (advancing isn't a user change), so that case always counts.
            if let previous = lastSeen[payload.id], let run = endedRun(previous, now: now),
               movedOnByClock(from: previous, to: payload) || !(payload.updatedAt.map { $0 < run.endedAt } ?? false) {
                runs.append(run)
            }
        }
        // Ended, then deleted before a scan saw it finished.
        for (id, previous) in lastSeen where !storedIDs.contains(id) {
            if let run = endedRun(previous, now: now) { runs.append(run) }
        }
        return runs
    }

    /// `current` is `previous` rolled forward to a later occurrence of its own rule
    /// (running, its end exactly a rule date) — not an extend or pause.
    static func movedOnByClock(from previous: TimerPayload, to current: TimerPayload) -> Bool {
        guard let rule = previous.recurrence, current.recurrence != nil, current.pausedRemaining == nil,
              current.endDate > previous.endDate,
              let occurrence = rule.nextDate(after: current.endDate.addingTimeInterval(-1)) else { return false }
        return abs(occurrence.timeIntervalSince(current.endDate)) < 1
    }

    static func endedRun(_ payload: TimerPayload, now: Date) -> TimerHistoryEntry? {
        if payload.recurrence != nil {
            // One entry per occurrence: the stored end is this year's, until the app
            // rolls it forward.
            guard payload.pausedRemaining == nil, payload.endDate <= now else { return nil }
            return TimerHistoryEntry(payload, endedAt: payload.endDate)
        }
        let current = payload.advancedSequence(at: now)
        if let sequence = current.sequence {
            guard sequence.loopIndex >= sequence.loopCount else { return nil }
            var entry = TimerHistoryEntry(current, endedAt: min(current.endDate, now))
            entry.label = payload.sequence?.phases.first?.label ?? current.label
            return entry
        }
        // Against `now`, not `isFinished` (which reads the wall clock).
        if let paused = current.pausedRemaining {
            // Paused exactly at zero: keyed on the stored end, which doesn't move —
            // `now` made a new entry on every scan.
            guard paused <= 0 else { return nil }
            return TimerHistoryEntry(current, endedAt: current.endDate)
        }
        guard current.endDate <= now else { return nil }
        return TimerHistoryEntry(current, endedAt: current.endDate)
    }

    /// Adds `runs` to `existing`, skipping ones already logged, pruning old entries;
    /// newest first.
    static func merged(_ existing: [TimerHistoryEntry], adding runs: [TimerHistoryEntry], now: Date) -> [TimerHistoryEntry] {
        var seen = Set(existing.map(\.id))
        var all = existing
        for run in runs where seen.insert(run.id).inserted { all.append(run) }
        return Array(all.filter { now.timeIntervalSince($0.endedAt) <= retention }
            .sorted { $0.endedAt > $1.endedAt }
            .prefix(limit))
    }

    // MARK: Store

    static func all() -> [TimerHistoryEntry] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TimerHistoryEntry].self, from: data)) ?? []
    }

    static func remove(id: String) {
        lock.withLock { save(all().filter { $0.id != id }) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        lock.withLock { save([]) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Forget several runs at once (a grouped row).
    static func remove(ids: Set<String>) {
        lock.withLock { save(all().filter { !ids.contains($0.id) }) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Undo of a Forget: puts the runs back (the usual 90-day / 200-run rules apply).
    static func restore(_ entries: [TimerHistoryEntry], now: Date = Date()) {
        lock.withLock { save(merged(all(), adding: entries, now: now)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: Grouping (History redesign, owner's pick A, 2026-11-27,
    // https://claude.ai/artifact/UACWYmfb7fzjSVR77LZUim)

    /// Runs of one timer on one day: the same name (ignoring case and surrounding
    /// spaces), kind, length to the second and repeat — so an 8-minute and a 10-minute
    /// Pasta stay apart. Newest run first.
    struct Group: Identifiable, Hashable {
        let day: Date
        let entries: [TimerHistoryEntry]
        var latest: TimerHistoryEntry { entries[0] }
        var id: String { "\(Int(day.timeIntervalSince1970))|\(TimerHistory.groupKey(latest))" }
    }

    static func groupKey(_ entry: TimerHistoryEntry) -> String {
        let name = entry.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shape = entry.sequence.map { "seq\($0.phases.count)x\($0.loopCount)" } ?? entry.kind.rawValue
        let repeats = entry.frequency?.rawValue ?? (entry.yearly ? "yearly" : "")
        return "\(name)|\(shape)|\(Int(entry.length.rounded()))|\(repeats)"
    }

    /// Days newest first; within a day, groups by their newest run.
    static func grouped(_ entries: [TimerHistoryEntry], calendar: Calendar = .current) -> [(day: Date, groups: [Group])] {
        var days: [Date: [String: [TimerHistoryEntry]]] = [:]
        for entry in entries {
            days[calendar.startOfDay(for: entry.endedAt), default: [:]][groupKey(entry), default: []].append(entry)
        }
        return days.keys.sorted(by: >).map { day in
            let groups = days[day]!.values
                .map { Group(day: day, entries: $0.sorted { $0.endedAt > $1.endedAt }) }
                .sorted { $0.latest.endedAt > $1.latest.endedAt }
            return (day, groups)
        }
    }

    /// When History is full (200 runs), the oldest run's end: earlier days aren't
    /// empty, they just aren't kept. nil while everything from the last 90 days is here.
    static func dataStart(_ entries: [TimerHistoryEntry]) -> Date? {
        guard entries.count >= limit else { return nil }
        return entries.map(\.endedAt).min()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// `-SeedHistory` (simulator screenshots only — never compiled for a phone, so a
    /// UI test can't overwrite someone's real History): replaces History with realistic runs
    /// — a busy Pomodoro day, two Pasta lengths, a fasting streak, a countdown.
    static func seedForScreenshots(now: Date = Date()) {
        func entry(_ label: String, minutes: Double, hoursAgo: Double, kind: TimerKind = .timer, phases: Int = 0) -> TimerHistoryEntry {
            var payload: TimerPayload
            if phases > 0 {
                payload = .composeSequence(phases: (0..<phases).map { SequencePhase(label: $0 % 2 == 0 ? label : "Break", duration: $0 % 2 == 0 ? 1500 : 300) }, loopCount: 1)
                payload.label = label
            } else {
                payload = TimerPayload(label: label, duration: minutes * 60, kind: kind)
            }
            return TimerHistoryEntry(payload, endedAt: now.addingTimeInterval(-hoursAgo * 3600))
        }
        var runs: [TimerHistoryEntry] = []
        runs += (0..<12).map { entry("Pomodoro", minutes: 0, hoursAgo: 0.5 + Double($0) * 0.6, phases: 4) }
        runs += [entry("Pasta", minutes: 8, hoursAgo: 5), entry("Pasta", minutes: 8, hoursAgo: 6), entry("Pasta", minutes: 8, hoursAgo: 7.5),
                 entry("Pasta", minutes: 10, hoursAgo: 8), entry("Tea", minutes: 4, hoursAgo: 26),
                 entry("Grandma's 90th birthday dinner at the lake house", minutes: 60 * 24 * 20, hoursAgo: 29, kind: .countdown)]
        runs += (1...5).map { entry("16:8 fast", minutes: 960, hoursAgo: Double($0) * 24 - 6) }
        runs += (2...9).map { entry("Run", minutes: 30, hoursAgo: Double($0) * 24 + 3) }
        lock.withLock { save(merged([], adding: runs, now: now)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    #endif

    /// Posted on the main thread after the log changes.
    static let changed = Notification.Name("TimerHistory.changed")

    /// Records whatever has ended since the last scan.
    static func scan(now: Date = Date()) {
        // Never from the unit/device test host (its fixtures would land in the owner's
        // real History) — `start()` is skipped there too, but foregrounding scans.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let stored = TimerStore.loadAll()
        let didChange: Bool = lock.withLock {
            let runs = endedRuns(stored: stored, lastSeen: lastSeen, now: now)
            lastSeen = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            guard !runs.isEmpty else { return false }
            let before = all()
            let after = merged(before, adding: runs, now: now)
            guard after != before else { return false }
            save(after)
            return true
        }
        if didChange {
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    /// Chains onto `TimerStore.didPersist` (after Spotlight installs its own hook) and
    /// takes a first look. The hook runs under the store's write lock, so it only
    /// schedules the scan.
    @MainActor
    static func start() {
        let previous = TimerStore.didPersist
        TimerStore.didPersist = {
            previous?()
            DispatchQueue.main.async { scan() }
        }
        scan()
    }

    private static func save(_ entries: [TimerHistoryEntry]) {
        defaults?.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
