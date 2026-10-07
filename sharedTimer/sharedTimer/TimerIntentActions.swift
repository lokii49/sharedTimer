import AppIntents
import Foundation

/// Pure state checks are separate from side effects so Siri's stale selections,
/// scheduled starts and background sequence catch-up can be tested without alarms.
enum TimerIntentActions {
    enum Mutation {
        case pause, resume, extend(minutes: Double)

        var action: String {
            switch self {
            case .pause: return "paused"
            case .resume: return "resumed"
            case .extend: return "extended"
            }
        }
    }

    enum Status { case scheduled, running, paused, finished }

    struct Snapshot {
        let payload: TimerPayload
        let seconds: Double
        let status: Status
    }

    static func snapshot(_ stored: TimerPayload?, at date: Date = Date()) throws -> Snapshot {
        guard let stored else { throw TimerIntentError.timerNotFound }
        let payload = stored.advancedSequence(at: date)
        let exhausted = payload.sequence.map { $0.loopIndex >= $0.loopCount } ?? false
        let seconds = exhausted ? 0 : max(0, payload.pausedRemaining ?? payload.endDate.timeIntervalSince(date))
        let status: Status = seconds <= 0 ? .finished : payload.isPending(at: date) ? .scheduled
            : payload.isPaused ? .paused : .running
        return Snapshot(payload: payload, seconds: seconds, status: status)
    }

    static func updated(_ stored: TimerPayload?, mutation: Mutation, at date: Date = Date()) throws -> TimerPayload {
        // Validate before doing arithmetic: infinity / NaN must never get saved or
        // passed to AlarmKit, and minutes * 60 can overflow even for a finite input.
        if case .extend(let minutes) = mutation {
            guard minutes.isFinite, minutes > 0, (minutes * 60).isFinite else {
                throw TimerIntentError.nonPositiveMinutes
            }
        }
        let current = try snapshot(stored, at: date)
        guard current.status != .scheduled else { throw TimerIntentError.timerScheduled }
        guard current.status != .finished else { throw TimerIntentError.timerFinished }
        switch mutation {
        case .pause: return current.payload.paused(at: date)
        case .resume: return current.payload.resumed(at: date)
        case .extend(let minutes):
            let interval = minutes * 60
            let end = (current.payload.pausedRemaining ?? current.payload.endDate.timeIntervalSinceReferenceDate) + interval
            guard end.isFinite else { throw TimerIntentError.nonPositiveMinutes }
            var updated = current.payload.extended(by: interval)
            updated.updatedAt = date
            return updated
        }
    }

    static func read(timerID: String) throws -> Snapshot {
        try snapshot(TimerStore.loadAll().first { $0.id == timerID })
    }

    static func perform(timerID: String, mutation: Mutation) async throws -> TimerPayload {
        // Use the ID only: a saved Shortcut's entity name/state can be days old.
        let stored = TimerStore.loadAll().first { $0.id == timerID }
        let updated = try updated(stored, mutation: mutation)
        if case .pause = mutation, stored?.isPaused == true { return updated }
        if case .resume = mutation, stored?.isPaused == false { return updated }
        TimerStore.save(updated)
        await TimerArming.armAwaiting(updated)
        // Refresh local surfaces before waiting for the best-effort cloud upload.
        WatchSyncController.pushCurrentState()
        await MainActor.run {
            TimerShortcuts.updateAppShortcutParameters()
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        }
        await TimerSpotlightIndex.shared.refreshAwaiting()
        await CloudSyncController.pushUpAwaiting(updated, action: mutation.action)
        return updated
    }

    static func spokenTime(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: ceil(max(0, seconds))) ?? "0 seconds"
    }
}
