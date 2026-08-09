//
//  TimerModel.swift
//  sharedTimer
//

import Foundation

struct TimerPayload: Codable, Identifiable {
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
}
