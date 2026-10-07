import Foundation

/// Local to the Watch. The phone supplies snapshots through WatchConnectivity;
/// this App Group only connects the Watch app and its WidgetKit extension.
enum WatchTimerCache {
    static let key = "watchTimerSnapshot.v1"
    static var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.lokesh.sharedTimer") }

    static func load(from defaults: UserDefaults? = defaults) -> [TimerPayload] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TimerPayload].self, from: data)) ?? []
    }

    @discardableResult
    static func save(_ timers: [TimerPayload], to defaults: UserDefaults? = defaults) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(timers) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

struct WatchTimerSnapshot {
    let date: Date
    let timer: TimerPayload?
    var remaining: TimeInterval {
        guard let timer else { return 0 }
        return max(0, timer.pausedRemaining ?? timer.endDate.timeIntervalSince(date))
    }
    var isRunning: Bool { timer != nil && timer?.pausedRemaining == nil && remaining > 0 }
    var status: String {
        guard let timer else { return "No Timers" }
        if remaining <= 0 { return "Done" }
        return timer.isPaused ? "Paused" : "Remaining"
    }
    var progress: Double { min(1, remaining / max(1, timer?.duration ?? 1)) }

    static func select(_ timers: [TimerPayload], id: String? = nil, at date: Date) -> WatchTimerSnapshot {
        // A removed configured timer stays empty; never silently switch to another.
        if let id { return Self(date: date, timer: timers.first { $0.id == id }) }
        let running = timers.filter { $0.pausedRemaining == nil && $0.endDate > date }
            .sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate < $1.endDate }
        let paused = timers.filter { ($0.pausedRemaining ?? 0) > 0 }
            .sorted { $0.id < $1.id }
        return Self(date: date, timer: running.first ?? paused.first)
    }

    /// The completion entry shows Done even if the extension never runs again.
    static func timeline(_ timers: [TimerPayload], id: String?, at date: Date) -> [WatchTimerSnapshot] {
        let first = select(timers, id: id, at: date)
        guard first.isRunning, let timer = first.timer else { return [first] }
        return [first, Self(date: timer.endDate, timer: timer)]
    }
}

enum WatchTimerLink {
    static func url(id: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "sharedtimer-watch"
        parts.host = "timer"
        parts.path = "/" + id
        return parts.url
    }
    static func id(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "sharedtimer-watch", parts.host == "timer",
              parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.hasPrefix("/"), parts.path.count > 1 else { return nil }
        return String(parts.path.dropFirst())
    }
}
