//
//  BackgroundRefresh.swift
//  sharedTimer
//
//  Best-effort refill of the pre-armed alert windows while the app isn't opened.
//  Sequences pre-arm 8 phase occurrences and yearly countdowns two years (see CLAUDE.md);
//  both windows otherwise only refill when the app runs. iOS decides when (and whether)
//  a BGAppRefreshTask runs — often hours apart, never on a schedule — so this narrows
//  the gap, it doesn't close it.
//
//  Main app only. Re-derives and re-arms, and refreshes existing custom Live
//  Activities (a long quiet timer's coarse "1d 6h"); never starts one (ActivityKit
//  can't from the background) and never pushes to CloudKit (clock-driven advances are
//  local, same as ContentView's "sequenceAdvanced").
//

import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Shortcuts.plist.
    static let identifier = "com.lokesh.sharedTimer.refreshAlerts"

    /// Call once, before `didFinishLaunching` returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task {
                await refillWindows()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Asks for the next run; only worth it while a sequence or yearly countdown exists,
    /// or a quiet timer's custom Live Activity shows a coarse "1d 6h" that goes stale.
    static func schedule() {
        guard TimerStore.loadAll().contains(where: { needsRefill($0) || needsCardRefresh($0) }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("SharedTimer: BGAppRefreshTask submit failed: \(error)")
        }
    }

    private static func needsRefill(_ payload: TimerPayload) -> Bool {
        (payload.sequence != nil || payload.recurrence != nil) && !payload.isPaused && !payload.isFinished
    }

    /// A quiet (custom Live Activity) timer about a day or more out: its card shows a static
    /// day/hour figure and only redraws on an update, so a background run refreshes it.
    private static func needsCardRefresh(_ payload: TimerPayload) -> Bool {
        // Down to 18h, not 24h: the redraw that swaps "1d" for the live count has to
        // happen after it crosses the day, not just before.
        !payload.isPaused && payload.remaining > 18 * 3600 && !AlarmController.ownsAlert(for: payload)
    }

    @MainActor
    static func refillWindows() async {
        for stored in TimerStore.loadAll() where stored.sequence == nil && stored.recurrence == nil && needsCardRefresh(stored) {
            guard !Task.isCancelled else { return }
            await LiveActivityController.updateAwaiting(for: stored)
        }
        for stored in TimerStore.loadAll() {
            guard !Task.isCancelled else { return }
            let current = stored.advancedSequence()
            guard needsRefill(current) else { continue }
            if current.endDate != stored.endDate { TimerStore.save(current) }
            await AlarmController.rescheduleAwaiting(for: current)
            // Updating an existing activity is allowed in the background (starting
            // one isn't): moves a quiet sequence's card to its current phase, so it
            // doesn't sit at 00:00 past the first boundary the card can follow itself,
            // and refreshes a quiet yearly countdown's coarse figure.
            if !AlarmController.ownsAlert(for: current) {
                await LiveActivityController.updateAwaiting(for: current)
            }
        }
        WatchSyncController.pushCurrentState()
        NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
    }
}
