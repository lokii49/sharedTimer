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

    /// Re-pushes every running timer's still-live Activity, resetting its no-update
    /// budget (iOS ends an activity roughly 8h after its last push) before a long
    /// countdown's Live Activity ages out. Deliberately calls `update`, not `start`:
    /// "no matching activity" is indistinguishable here from "the system aged it out"
    /// vs. "the person swiped it away on the Lock Screen" — recreating in the second
    /// case would make a dismissed Live Activity reappear on every foreground. Call
    /// opportunistically (e.g. app foregrounding) — there's no server here to push
    /// this on a schedule while the app isn't running.
    static func refreshAll(from payloads: [TimerPayload]) {
        for payload in payloads where !payload.isPaused && !payload.isFinished {
            update(for: payload)
        }
    }

    private static func content(for payload: TimerPayload) -> ActivityContent<TimerActivityAttributes.ContentState> {
        ActivityContent(
            state: TimerActivityAttributes.ContentState(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining),
            staleDate: nil
        )
    }
}
