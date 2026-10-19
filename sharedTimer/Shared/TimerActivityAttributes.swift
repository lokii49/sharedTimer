//
//  TimerActivityAttributes.swift
//  Shared
//

import ActivityKit
import Foundation

struct TimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var pausedRemaining: TimeInterval?
        // The attributes below are fixed when the activity is requested, so anything
        // that can change on a running activity travels here instead: the current
        // phase's (or an edited timer's) label and kind, and a sequence's next quiet
        // phases. All optional, so an activity started by an older build still decodes.
        var label: String? = nil
        var kind: TimerKind? = nil
        var upcoming: [Phase]? = nil
    }

    /// A later sequence phase the card can switch to on its own when the current one
    /// ends while the app isn't running (see `ContentState.current(at:)`).
    struct Phase: Codable, Hashable {
        var label: String
        var kind: TimerKind
        var endDate: Date
    }

    var timerID: String
    var label: String
    var kind: TimerKind
}

extension TimerActivityAttributes.ContentState {
    /// What the card should show at `date`. With the app closed, a custom Live Activity
    /// only re-renders at its `staleDate` (the current phase's end); at that moment this
    /// moves on to the next quiet phase carried in `upcoming`, instead of the card
    /// reading "Finished" while the sequence is still running.
    func current(at date: Date) -> Self {
        guard pausedRemaining == nil, endDate <= date, let upcoming,
              let index = upcoming.firstIndex(where: { $0.endDate > date }) else { return self }
        var copy = self
        copy.endDate = upcoming[index].endDate
        copy.label = upcoming[index].label
        copy.kind = upcoming[index].kind
        copy.upcoming = Array(upcoming[(index + 1)...])
        return copy
    }
}
