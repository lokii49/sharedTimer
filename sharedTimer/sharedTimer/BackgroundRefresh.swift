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
//  Main app only. Re-derives and re-arms; never starts a Live Activity (ActivityKit
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

    /// Asks for the next run; only worth it while a sequence or yearly countdown exists.
    static func schedule() {
        guard TimerStore.loadAll().contains(where: needsRefill) else {
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

    @MainActor
    static func refillWindows() async {
        for stored in TimerStore.loadAll() {
            guard !Task.isCancelled else { return }
            let current = stored.advancedSequence()
            guard needsRefill(current) else { continue }
            if current.endDate != stored.endDate { TimerStore.save(current) }
            await AlarmController.rescheduleAwaiting(for: current)
        }
        WatchSyncController.pushCurrentState()
        NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
    }
}
