//
//  TimerModel.swift
//  sharedTimerMessages
//

import Foundation

struct TimerPayload: Codable {
    let id: String
    let label: String
    let endDate: Date

    init(id: String = UUID().uuidString, label: String, duration: TimeInterval) {
        self.id = id
        self.label = label
        self.endDate = Date().addingTimeInterval(duration)
    }

    init(id: String, label: String, endDate: Date) {
        self.id = id
        self.label = label
        self.endDate = endDate
    }

    var remaining: TimeInterval {
        max(0, endDate.timeIntervalSinceNow)
    }

    var isExpired: Bool {
        remaining <= 0
    }

    func url() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(endDate.timeIntervalSince1970))
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
        return TimerPayload(id: id, label: label, endDate: Date(timeIntervalSince1970: endInterval))
    }
}
