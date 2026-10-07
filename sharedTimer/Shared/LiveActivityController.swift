//
//  LiveActivityController.swift
//  Shared
//

import ActivityKit
import Foundation

enum LiveActivityController {
    static func start(for payload: TimerPayload) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A Live Activity's no-update budget is ~8h (see `refreshAll` below) -- starting
        // one for a payload that may not even begin running for days would just die
        // long before the timer does. `armAlerts` still schedules the real alert
        // (AlarmKit/notification) immediately regardless -- only this cosmetic surface
        // waits. Once the start time passes, the next `armAlerts` call (foregrounding,
        // or any other mutation) starts it normally.
        guard !payload.isPending() else { return }

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
    /// Ends the Live Activity of every finished payload: its final state lingers on
    /// the Lock Screen for a few minutes (so a glance still shows "Finished"), then
    /// the system removes it. Called when the app sees a finish — the live zero
    /// crossing and on every launch/foreground — since nothing can run at the finish
    /// moment itself while the app is closed (the staleDate covers that gap).
    static func endFinished(_ payloads: [TimerPayload]) {
        for payload in payloads where payload.isFinished && !payload.isPaused {
            let dismissal = max(Date(), payload.endDate).addingTimeInterval(5 * 60)
            Task {
                for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == payload.id {
                    await activity.end(content(for: payload), dismissalPolicy: .after(dismissal))
                }
            }
        }
    }

    static func refreshAll(from payloads: [TimerPayload]) {
        for payload in payloads where !payload.isPaused && !payload.isFinished {
            update(for: payload)
        }
    }

    private static func content(for payload: TimerPayload) -> ActivityContent<TimerActivityAttributes.ContentState> {
        ActivityContent(
            state: TimerActivityAttributes.ContentState(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining),
            // Stale at the finish moment: when the app isn't running to end it, the
            // system still re-renders the card as stale, and TimerLiveActivityWidget
            // shows "Finished" (no buttons) instead of a frozen 0:00 for hours.
            staleDate: payload.isPaused ? nil : payload.endDate
        )
    }
}
