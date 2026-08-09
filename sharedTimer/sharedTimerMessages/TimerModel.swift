//
//  TimerModel.swift
//  sharedTimerMessages
//

import Foundation

enum TimerShareMode {
    case appCard
    case link
}

struct TimerPayload: Codable {
    let id: String
    let label: String
    let endDate: Date
    let duration: TimeInterval

    init(id: String = UUID().uuidString, label: String, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
    }

    init(id: String, label: String, endDate: Date, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.endDate = endDate
        self.duration = duration
    }

    var remaining: TimeInterval {
        max(0, endDate.timeIntervalSinceNow)
    }

    var isExpired: Bool {
        remaining <= 0
    }

    /// Fraction of the timer remaining, for progress rings. 1 = just started, 0 = done.
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let remaining = endDate.timeIntervalSince(date)
        return min(1, max(0, remaining / duration))
    }

    func url() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(endDate.timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: String(duration))
        ]
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
        return TimerPayload(id: id, label: label, endDate: endDate, duration: duration)
    }
}
