import Foundation

/// ID-only app links: opening a stale widget must never import its old timer snapshot.
enum TimerAppLink {
    static func url(for timerID: String) -> URL {
        var components = URLComponents()
        components.scheme = "sharedtimer"
        components.host = "timer"
        components.path = "/" + timerID
        return components.url!
    }

    static func timerID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sharedtimer",
              components.host?.lowercased() == "timer",
              components.query == nil, components.fragment == nil,
              components.path.hasPrefix("/") else { return nil }
        let id = String(components.path.dropFirst())
        return id.isEmpty ? nil : id
    }
}

/// Pure/date-parameterized state shared by accessory widgets and their tests.
struct TimerWidgetSnapshot {
    enum Status { case empty, scheduled, running, paused, finished }
    let date: Date
    let payload: TimerPayload?

    init(payload: TimerPayload?, at date: Date) {
        self.date = date
        self.payload = payload?.advancedSequence(at: date)
    }

    var remaining: TimeInterval {
        guard let payload else { return 0 }
        return max(0, payload.pausedRemaining ?? payload.endDate.timeIntervalSince(date))
    }

    var status: Status {
        guard let payload else { return .empty }
        if let sequence = payload.sequence, sequence.loopIndex >= sequence.loopCount { return .finished }
        if remaining <= 0 { return .finished }
        if payload.isPending(at: date) { return .scheduled }
        return payload.isPaused ? .paused : .running
    }

    var progress: Double {
        guard status == .running || status == .paused, let payload else { return 0 }
        return payload.progress(at: date)
    }

    var timerInterval: ClosedRange<Date>? {
        guard status == .running, let payload, payload.duration.isFinite, payload.duration > 0 else { return nil }
        return payload.endDate.addingTimeInterval(-payload.duration)...payload.endDate
    }

    static func resolve(from payloads: [TimerPayload], selectedID: String?, focusID: String?, at date: Date) -> TimerPayload? {
        let current = payloads.map { $0.advancedSequence(at: date) }
        if let selectedID, let selected = current.first(where: { $0.id == selectedID }) { return selected }
        if let focusID, let focused = current.first(where: { $0.id == focusID }),
           TimerWidgetSnapshot(payload: focused, at: date).status != .finished || focused.endDate > date.addingTimeInterval(-3600) {
            return focused
        }
        let active = current.filter { TimerWidgetSnapshot(payload: $0, at: date).status != .finished }
        let running = active.filter { !$0.isPaused }.sorted { $0.endDate < $1.endDate }
        let paused = active.filter(\.isPaused).sorted {
            ($0.pausedRemaining ?? 0) < ($1.pausedRemaining ?? 0)
        }
        return running.first ?? paused.first
    }

    /// Supply explicit future entries for scheduled starts, phase changes and finish,
    /// rather than hoping WidgetKit requests a new timeline exactly at each boundary.
    static func timeline(payload: TimerPayload?, at date: Date, limit: Int = 8) -> [TimerWidgetSnapshot] {
        let first = TimerWidgetSnapshot(payload: payload, at: date)
        guard let current = first.payload, first.status == .scheduled || first.status == .running else { return [first] }
        var dates: [Date] = []
        if first.status == .scheduled, let start = current.scheduledStartDate { dates.append(start) }
        if current.sequence != nil {
            dates += current.upcomingSequencePhases(limit: max(1, limit)).map(\.endDate)
        } else {
            dates.append(current.endDate)
        }
        let future = Array(Set(dates.filter { $0 > date })).sorted().prefix(max(1, limit))
        return [first] + future.map { TimerWidgetSnapshot(payload: current, at: $0) }
    }

    static func refreshDate(for snapshots: [TimerWidgetSnapshot]) -> Date {
        guard let first = snapshots.first else { return Date().addingTimeInterval(900) }
        guard first.status == .running || first.status == .scheduled else { return first.date.addingTimeInterval(900) }
        let last = snapshots.last!.date.addingTimeInterval(1)
        // Long countdown labels are coarse and need periodic updates. Also refresh
        // exactly when they enter the live (<24h) or calendar/day formatting range.
        if first.remaining > TimeFormat.calendarThreshold {
            return min(last, first.date.addingTimeInterval(min(first.remaining - TimeFormat.calendarThreshold, 21600)))
        }
        if first.remaining >= 86400 {
            return min(last, first.date.addingTimeInterval(max(1, min(first.remaining - 86400, 3600))))
        }
        return last
    }
}
