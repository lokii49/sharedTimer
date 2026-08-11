//
//  TimerActivityAttributes.swift
//  sharedTimer
//

import ActivityKit
import Foundation

struct TimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var pausedRemaining: TimeInterval?
    }

    var timerID: String
    var label: String
}
