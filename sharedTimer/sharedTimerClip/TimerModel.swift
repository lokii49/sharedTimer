//
//  TimerModel.swift
//  sharedTimerClip
//

import Foundation

enum TimerShareMode: String, Codable {
    case appCard
    case link
}

enum TimerKind: String, Codable {
    case timer
    case countdown
}

struct TimerPayload: Codable, Identifiable {
    let id: String
    let label: String
    var endDate: Date
    let duration: TimeInterval
    var pausedRemaining: TimeInterval?
    let kind: TimerKind

    init(id: String = UUID().uuidString, label: String, duration: TimeInterval, kind: TimerKind = .timer) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
        self.pausedRemaining = nil
        self.kind = kind
    }

    init(id: String, label: String, endDate: Date, duration: TimeInterval, pausedRemaining: TimeInterval? = nil, kind: TimerKind = .timer) {
        self.id = id
        self.label = label
        self.endDate = endDate
        self.duration = duration
        self.pausedRemaining = pausedRemaining
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, endDate, duration, pausedRemaining, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        endDate = try container.decode(Date.self, forKey: .endDate)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        pausedRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        // Older shared links/stored timers predate `kind`; treat them as plain timers.
        kind = try container.decodeIfPresent(TimerKind.self, forKey: .kind) ?? .timer
    }

    var isPaused: Bool {
        pausedRemaining != nil
    }

    var remaining: TimeInterval {
        if let pausedRemaining {
            return max(0, pausedRemaining)
        }
        return max(0, endDate.timeIntervalSinceNow)
    }

    var isExpired: Bool {
        !isPaused && remaining <= 0
    }

    /// Fraction of the timer remaining, for progress rings. 1 = just started, 0 = done.
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let currentRemaining = isPaused ? (pausedRemaining ?? 0) : endDate.timeIntervalSince(date)
        return min(1, max(0, currentRemaining / duration))
    }

    func paused(at date: Date = Date()) -> TimerPayload {
        guard !isPaused else { return self }
        var copy = self
        copy.pausedRemaining = max(0, endDate.timeIntervalSince(date))
        return copy
    }

    func resumed(at date: Date = Date()) -> TimerPayload {
        guard let pausedRemaining else { return self }
        var copy = self
        copy.endDate = date.addingTimeInterval(pausedRemaining)
        copy.pausedRemaining = nil
        return copy
    }

    func extended(by interval: TimeInterval) -> TimerPayload {
        var copy = self
        if let pausedRemaining = copy.pausedRemaining {
            copy.pausedRemaining = max(0, pausedRemaining + interval)
        } else {
            copy.endDate = copy.endDate.addingTimeInterval(interval)
        }
        return copy
    }

    /// Builds a payload from compose-sheet inputs shared by every creation surface (Messages, main app).
    static func compose(label: String, kind: TimerKind, minutes: Double, targetDate: Date) -> TimerPayload {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmed.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : trimmed
        switch kind {
        case .timer:
            return TimerPayload(label: finalLabel, duration: max(1, minutes * 60), kind: .timer)
        case .countdown:
            return TimerPayload(label: finalLabel, duration: max(1, targetDate.timeIntervalSinceNow), kind: .countdown)
        }
    }

    func url() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        var items = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(endDate.timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: String(duration)),
            URLQueryItem(name: "kind", value: kind.rawValue)
        ]
        if let pausedRemaining {
            items.append(URLQueryItem(name: "paused", value: String(pausedRemaining)))
        }
        components.queryItems = items
        return components.url!
    }

    static func from(url: URL?) -> TimerPayload? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              let label = items.first(where: { $0.name == "label" })?.value,
              let endString = items.first(where: { $0.name == "end" })?.value,
              let endInterval = Double(endString) else {
            return nil
        }
        let endDate = Date(timeIntervalSince1970: endInterval)
        let durString = items.first(where: { $0.name == "dur" })?.value
        let duration = durString.flatMap(Double.init) ?? max(endDate.timeIntervalSinceNow, 1)
        let pausedRemaining = items.first(where: { $0.name == "paused" })?.value.flatMap(Double.init)
        let kind = items.first(where: { $0.name == "kind" })?.value.flatMap(TimerKind.init(rawValue:)) ?? .timer
        return TimerPayload(id: id, label: label, endDate: endDate, duration: duration, pausedRemaining: pausedRemaining, kind: kind)
    }
}

/// Day-aware time formatting shared by every surface that renders a countdown.
enum TimeFormat {
    /// "3d 04:12:09" beyond a day, "4:12:09" beyond an hour, else "12:09".
    static func remaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, h, m, s)
        }
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Compact "12d" form for tight widget/glanceable layouts.
    static func compactDays(_ interval: TimeInterval) -> String {
        "\(max(0, Int(interval) / 86400))d"
    }

    /// "2026-08-11" target date, e.g. for countdown rows and share text.
    static func targetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
