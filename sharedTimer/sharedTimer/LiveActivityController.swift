//
//  LiveActivityController.swift
//  sharedTimer
//

import ActivityKit
import Foundation

enum LiveActivityController {
    static func start(for payload: TimerPayload) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let existing = Activity<TimerActivityAttributes>.activities.first(where: { $0.attributes.timerID == payload.id }) {
            Task { await existing.update(content(for: payload)) }
            return
        }

        let attributes = TimerActivityAttributes(timerID: payload.id, label: payload.label, kind: payload.kind)
        do {
            _ = try Activity.request(attributes: attributes, content: content(for: payload))
        } catch {
            print("SharedTimer live activity start error: \(error)")
        }
    }

    static func update(for payload: TimerPayload) {
        Task {
            for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == payload.id {
                await activity.update(content(for: payload))
            }
        }
    }

    static func end(id: String) {
        Task {
            for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func content(for payload: TimerPayload) -> ActivityContent<TimerActivityAttributes.ContentState> {
        ActivityContent(
            state: TimerActivityAttributes.ContentState(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining),
            staleDate: nil
        )
    }
}
