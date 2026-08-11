//
//  TimerModel.swift
//  sharedTimerClip
//

import Foundation

enum TimerShareMode: String, Codable {
    case appCard
    case link
}

struct TimerPayload: Codable, Identifiable {
    let id: String
    let label: String
    var endDate: Date
    let duration: TimeInterval
    var pausedRemaining: TimeInterval?

    init(id: String = UUID().uuidString, label: String, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
        self.pausedRemaining = nil
    }

    init(id: String, label: String, endDate: Date, duration: TimeInterval, pausedRemaining: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.endDate = endDate
        self.duration = duration
        self.pausedRemaining = pausedRemaining
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

    func url() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        var items = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(endDate.timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: String(duration))
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
        return TimerPayload(id: id, label: label, endDate: endDate, duration: duration, pausedRemaining: pausedRemaining)
    }
}
