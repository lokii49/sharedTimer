import Foundation
import WidgetKit

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
        guard let timer else { return String(localized: "No Timers") }
        if remaining <= 0 { return String(localized: "Done") }
        return timer.isPaused ? String(localized: "Paused") : String(localized: "Remaining")
    }
    /// VoiceOver: the timer's name is the label, this is the value — like the phone's
    /// Lock Screen widget. A running timer says when it ends (fixed and true for the
    /// whole entry), never a "time left" that was right only when the entry was made.
    var accessibilityName: String { timer?.label ?? String(localized: "Timer") }
    var accessibilityValue: String {
        guard let timer else { return String(localized: "Sync timers from iPhone") }
        if remaining <= 0 { return String(localized: "Done") }
        if timer.isPaused { return String(localized: "Paused, \(TimeFormat.display(remaining, at: date)) remaining") }
        return String(localized: "Running, ends \(timer.endDate.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Smart Stack order, the phone home widgets' rule (`TimerEntry.relevance`): a timer
    /// in its last hour first, then other running ones, paused low, done/empty none.
    /// Only ranks this widget's entries against others; it never adds the widget.
    var relevance: TimelineEntryRelevance {
        guard timer != nil, remaining > 0 else { return TimelineEntryRelevance(score: 0) }
        if !isRunning { return TimelineEntryRelevance(score: 10) }
        return TimelineEntryRelevance(score: remaining <= 3600 ? 100 : 50, duration: remaining)
    }

    /// Against the whole run, extends included (the phone's `span`).
    var progress: Double { min(1, remaining / max(1, timer.map { $0.duration + $0.extraTime } ?? 1)) }

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
        // The last hour gets its own entry so its higher relevance applies (no reload).
        let lastHour = timer.endDate.addingTimeInterval(-3600)
        let middle = lastHour > date ? [Self(date: lastHour, timer: timer)] : []
        return [first] + middle + [Self(date: timer.endDate, timer: timer)]
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
