import Foundation
import WidgetKit

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
        return payload.endDate.addingTimeInterval(-payload.span)...payload.endDate
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
        if first.status == .scheduled, let start = current.scheduledStartDate {
            dates.append(start)
            // "Tomorrow 7:00 AM" must read "Today 7:00 AM" after midnight.
            let calendar = Calendar.current
            var midnight = calendar.startOfDay(for: date)
            for _ in 0..<2 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: midnight), next < start else { break }
                dates.append(next)
                midnight = next
            }
        }
        if current.sequence != nil {
            dates += current.upcomingSequencePhases(limit: max(1, limit)).map(\.endDate)
        } else {
            dates.append(current.endDate)
        }
        let future = Array(Set(dates.filter { $0 > date })).sorted().prefix(max(1, limit))
        return [first] + future.map { TimerWidgetSnapshot(payload: current, at: $0) }
    }

    /// Home-screen skies drain with time, but a widget can't animate a gradient: extra
    /// entries between the state boundaries redraw it (entries cost no reload budget —
    /// only reloads do). Before 1.0.9 the home widgets had a single entry, so a finish
    /// or phase change waited for a reload: "0:00" with Pause/✕ still showing, the old
    /// phase's label, a frozen sky.
    static func homeTimeline(payload: TimerPayload?, at date: Date, maxEntries: Int = 40) -> [TimerWidgetSnapshot] {
        let base = timeline(payload: payload, at: date)
        guard let first = base.first, first.status == .running, let current = first.payload,
              let horizon = base.last?.date, horizon > date else { return base }
        var dates = Set(base.map(\.date))
        // A coarse "3d 4h" changes on each whole hour: entries, not reloads.
        if first.remaining >= 86400 && first.remaining < TimeFormat.calendarThreshold {
            var rollover = date.addingTimeInterval(first.remaining.truncatingRemainder(dividingBy: 3600) + 1)
            while rollover < horizon && dates.count < maxEntries / 2 {
                dates.insert(rollover)
                rollover = rollover.addingTimeInterval(3600)
            }
        }
        let step = max(60, current.span / 24)
        var next = date.addingTimeInterval(step)
        while next < horizon && dates.count < maxEntries {
            dates.insert(next)
            next = next.addingTimeInterval(step)
        }
        return dates.sorted().map { TimerWidgetSnapshot(payload: current, at: $0) }
    }

    /// Entry dates for a widget listing several timers: every listed timer's own state
    /// boundaries (start, phase changes, finish), soonest first, capped.
    static func listDates(for payloads: [TimerPayload], at date: Date, maxEntries: Int = 40) -> [Date] {
        var dates: Set<Date> = [date]
        for payload in payloads {
            for snapshot in homeTimeline(payload: payload, at: date, maxEntries: 12) { dates.insert(snapshot.date) }
        }
        return Array(dates.filter { $0 >= date }.sorted().prefix(maxEntries))
    }

    /// Fallback for a widget with nothing on its clock (paused, empty, long finished).
    /// Every store save reloads all timelines (`TimerStore.persist`), but a save made in
    /// Messages or the notification service reaching the widget is unverified on device,
    /// so a slow safety net rather than `.never` — 4 a day, against the 96 the old
    /// 15-minute polling spent (over WidgetKit's budget, so the reloads that mattered
    /// were throttled).
    static let idleReloadInterval: TimeInterval = 6 * 3600

    /// When WidgetKit should ask for a new timeline.
    static func reloadDate(for snapshots: [TimerWidgetSnapshot]) -> Date {
        guard let first = snapshots.first else { return Date().addingTimeInterval(idleReloadInterval) }
        let idle = first.date.addingTimeInterval(idleReloadInterval)
        switch first.status {
        case .empty, .paused:
            return idle
        case .finished:
            // An auto-selected finished timer stays an hour (Repeat where it was
            // tapped), then gives way to the next running one; overtime also ends then.
            guard let end = first.payload?.endDate, end.addingTimeInterval(3600) > first.date else { return idle }
            return min(idle, end.addingTimeInterval(3600))
        case .running, .scheduled:
            return refreshDate(for: snapshots)
        }
    }

    static func reloadPolicy(for snapshots: [TimerWidgetSnapshot]) -> TimelineReloadPolicy {
        .after(reloadDate(for: snapshots))
    }

    /// A list widget's reload: each listed timer judged on the entry dates the list
    /// really has (it caps every timer's share), not on that timer's own full timeline —
    /// otherwise a row's coarse "3d 4h" counted on hourly entries the list didn't keep.
    static func listReloadDate(for payloads: [TimerPayload], dates: [Date], at date: Date) -> Date {
        let perTimer = payloads.map { payload in
            reloadDate(for: dates.map { TimerWidgetSnapshot(payload: payload, at: $0) })
        }
        return perTimer.min() ?? date.addingTimeInterval(idleReloadInterval)
    }

    static func refreshDate(for snapshots: [TimerWidgetSnapshot]) -> Date {
        guard let first = snapshots.first else { return Date().addingTimeInterval(900) }
        guard first.status == .running || first.status == .scheduled else { return first.date.addingTimeInterval(900) }
        var refresh = snapshots.last!.date.addingTimeInterval(1)
        // Long countdown labels are coarse and need periodic updates. Also refresh
        // exactly when they enter the live (<24h) or calendar/day formatting range.
        // Every entry counts, not just the first: a later sequence phase of a day or
        // more otherwise showed a frozen "2d 0h" from its start until the app saved.
        // A change already redrawn by the next entry needs no reload.
        for (index, snapshot) in snapshots.enumerated() where snapshot.status == .running || snapshot.status == .scheduled {
            var change: Date?
            if snapshot.remaining > TimeFormat.calendarThreshold {
                change = snapshot.date.addingTimeInterval(min(snapshot.remaining - TimeFormat.calendarThreshold, 21600))
            } else if snapshot.remaining >= 86400 {
                // "3d 4h" rounds down, so it changes when the remaining time crosses a
                // whole hour — refresh then, not up to an hour later.
                let toNextHour = snapshot.remaining.truncatingRemainder(dividingBy: 3600) + 1
                change = snapshot.date.addingTimeInterval(max(1, min(snapshot.remaining - 86400, toNextHour)))
            }
            let nextEntry = index + 1 < snapshots.count ? snapshots[index + 1].date : .distantFuture
            if let change, change < nextEntry { refresh = min(refresh, change) }
        }
        return refresh
    }
}
