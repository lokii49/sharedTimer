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
            // (`merged` drops it if it's the same run as above).
            if let previous = lastSeen[payload.id], let run = endedRun(previous, now: now) {
                runs.append(run)
            }
        }
        // Ended, then deleted before a scan saw it finished.
        for (id, previous) in lastSeen where !storedIDs.contains(id) {
            if let run = endedRun(previous, now: now) { runs.append(run) }
        }
        return runs
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
            guard paused <= 0 else { return nil }
            return TimerHistoryEntry(current, endedAt: now)
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

    /// Posted on the main thread after the log changes.
    static let changed = Notification.Name("TimerHistory.changed")

    /// Records whatever has ended since the last scan.
    static func scan(now: Date = Date()) {
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
