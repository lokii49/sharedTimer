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

        // An ended activity can linger (dismissal pending) — updating it does nothing,
        // so only reuse one that's still active.
        if let existing = activeActivity(for: payload.id) {
            Task { await existing.update(content(for: payload)) }
            return
        }
        request(payload)
    }

    /// `start`, awaited — for an intent's `perform()`, which the system may tear down
    /// as soon as it returns (same rule as `AlarmController.rescheduleAwaiting`).
    static func startAwaiting(for payload: TimerPayload) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, !payload.isPending() else { return }
        if let existing = activeActivity(for: payload.id) {
            await existing.update(content(for: payload))
            return
        }
        request(payload)
    }

    private static func activeActivity(for id: String) -> Activity<TimerActivityAttributes>? {
        Activity<TimerActivityAttributes>.activities.first { $0.attributes.timerID == id && $0.activityState == .active }
    }

    private static func request(_ payload: TimerPayload) {
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

    /// `end`, awaited — see `startAwaiting`.
    static func endAwaiting(id: String) async {
        for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// `update`, awaited — for an intent or background task that may be suspended once
    /// it returns.
    static func updateAwaiting(for payload: TimerPayload) async {
        for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == payload.id {
            await activity.update(content(for: payload))
        }
    }

    static func end(id: String) {
        Task {
            for activity in Activity<TimerActivityAttributes>.activities where activity.attributes.timerID == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

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
            state: TimerActivityAttributes.ContentState(
                endDate: payload.endDate, pausedRemaining: payload.pausedRemaining,
                label: payload.label, kind: payload.kind, upcoming: upcomingQuietPhases(of: payload)),
            // Stale at the finish moment: when the app isn't running to end it, the
            // system still re-renders the card as stale, and TimerLiveActivityWidget
            // shows "Finished" (no buttons) instead of a frozen 0:00 for hours. For a
            // sequence that same re-render switches to the next phase in `upcoming`.
            staleDate: payload.isPaused ? nil : payload.endDate
        )
    }

    /// The run of quiet phases right after the current one — the only ones this card
    /// shows. A phase with either toggle on gets AlarmKit's own Live Activity, so the
    /// list stops there (past it the card reads Finished and AlarmKit's takes over).
    /// Capped at 4 with short labels: ActivityKit content must stay under 4 KB, and a
    /// wire label can be 512 bytes.
    static func upcomingQuietPhases(of payload: TimerPayload) -> [TimerActivityAttributes.Phase]? {
        guard payload.sequence != nil else { return nil }
        let quiet = payload.upcomingSequencePhases(limit: 5).dropFirst()
            .prefix { !$0.phase.alarmEnabled && !$0.phase.vibrationEnabled }
        return quiet.map { TimerActivityAttributes.Phase(label: String($0.phase.label.prefix(60)), kind: $0.phase.kind, endDate: $0.endDate) }
    }
}
