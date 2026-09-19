//
//  AppDelegate.swift
//  sharedTimer
//
//  Exists to receive silent CloudKit push (see CloudSyncController) and apply the
//  resulting changes through the same TimerStore/NotificationScheduler/
//  LiveActivityController call sequence every other mutation path already uses.
//  Plugged into the otherwise pure-SwiftUI app lifecycle via
//  `@UIApplicationDelegateAdaptor` in sharedTimerApp.swift. Share ACCEPTANCE happens via
//  our own universal link (CloudSyncController.acceptShare), not via
//  `userDidAcceptCloudKitShareWith` — that's still true and still doesn't need a scene
//  delegate. `configurationForConnecting` below exists for a different reason: Home
//  Screen Quick Action taps (see SceneDelegate.swift) are only ever delivered to a
//  UIWindowSceneDelegate once an app has adopted scenes — there's no non-scene fallback.
//

import CloudKit
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.registerForRemoteNotifications()
        CloudSyncController.registerSubscriptionsIfNeeded()
        WatchSyncController.activate()
        // Ask for AlarmKit permission now so the prompt isn't racing the first
        // .timer's schedule call (see AlarmController).
        AlarmController.requestAuthorizationIfNeeded()
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Confirm this is actually a CloudKit notification before doing any work — a
        // defensive check, not currently load-bearing (this app has no other push source).
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }

        // Snapshot before any of this batch's saves land — compared per-payload below to
        // tell a genuine incoming extend from this device's own change echoing back
        // through the same silent-push subscription (TimerStore.save already ran before
        // ContentView.apply's CloudSyncController.pushUp, so a self-echo's endDate always
        // matches what's already here and the delta is zero).
        let priorState = Dictionary(uniqueKeysWithValues: TimerStore.loadAll().map { ($0.id, $0) })

        CloudSyncController.pullChanges { updated, deletedIDs in
            for payload in updated {
                let existing = priorState[payload.id]
                TimerStore.save(payload)
                // Same arming sequence as ContentView.armAlerts: AlarmKit alarm when
                // either toggle is on (either kind), local notification only when both
                // are off, and the custom Live Activity only for that both-off case
                // (AlarmKit runs its own whenever it owns the alert).
                AlarmController.reschedule(for: payload)
                if !AlarmController.ownsAlert(for: payload) {
                    if payload.isPaused {
                        LiveActivityController.update(for: payload)
                    } else {
                        LiveActivityController.start(for: payload)
                    }
                }
                if let existing {
                    self.notifyIfExtended(existing: existing, updated: payload)
                }
            }
            for id in deletedIDs {
                TimerStore.delete(id: id)
                AlarmController.clear(id: id)
                LiveActivityController.end(id: id)
            }
            if !updated.isEmpty || !deletedIDs.isEmpty {
                WatchSyncController.pushCurrentState()
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
            }
            completionHandler(updated.isEmpty && deletedIDs.isEmpty ? .noData : .newData)
        }
    }

    // MARK: - "Someone extended your timer" notification

    /// Category for the extend-awareness notification below — used only to opt it into
    /// a foreground banner (see `willPresent`); it carries no actions.
    private static let extendedCategoryID = "SHAREDTIMER_TIMER_EXTENDED"

    /// Posts a local, user-visible notification when a shared timer/countdown someone
    /// else is looking at was just extended — the silent CloudKit push that applies the
    /// change otherwise has zero visible signal, so the other participant would only
    /// find out by happening to reopen the app. Scoped deliberately narrow: only a pure
    /// extend (`endDate` moved forward, `duration`/pause state unchanged, the payload
    /// was actively running, not finished) triggers this — pause/resume fire far more
    /// often and would make this noisy, and a repeat looks superficially similar (its
    /// `endDate` also jumps forward) but always starts from a finished payload, which
    /// `existing.remaining > 0` excludes.
    private func notifyIfExtended(existing: TimerPayload, updated: TimerPayload) {
        let delta = updated.endDate.timeIntervalSince(existing.endDate)
        guard !existing.isPaused, !updated.isPaused,
              existing.duration == updated.duration,
              existing.remaining > 0,
              delta >= 5 else { return }

        CloudSyncController.fetchAttribution(for: updated) { attribution in
            let who = attribution?.name ?? "Someone"
            let content = UNMutableNotificationContent()
            content.title = updated.label
            content.body = "\(who) added \(Self.deltaText(delta)) — now ends at \(updated.endDate.formatted(date: .omitted, time: .shortened))"
            content.sound = .default
            content.categoryIdentifier = Self.extendedCategoryID
            // A fresh identifier per extend (not e.g. `updated.id` alone) so a second
            // extend before the first notification is seen adds rather than replaces —
            // each one is real, distinct news.
            let request = UNNotificationRequest(
                identifier: "\(updated.id)-extended-\(Int(updated.endDate.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func deltaText(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 && seconds == 0 { return "\(minutes) min" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    // MARK: - Vibration-only finish notification actions

    /// Lock-screen "Repeat"/"Stop" for a vibration-only finish notification (alarm off
    /// — see `NotificationScheduler.vibrationFinishCategoryID`), the closest available
    /// parity with AlarmKit's panel for a payload AlarmKit never touches (AlarmKit only
    /// handles the alarm-on case). Neither action takes `.foreground` — both process
    /// silently without opening the app, which is the point.
    private func registerNotificationCategories() {
        let repeatAction = UNNotificationAction(identifier: "REPEAT_ACTION", title: "Repeat", options: [])
        let stopAction = UNNotificationAction(identifier: "STOP_ACTION", title: "Stop", options: [])
        let vibrationFinishCategory = UNNotificationCategory(
            identifier: NotificationScheduler.vibrationFinishCategoryID,
            actions: [stopAction, repeatAction],
            intentIdentifiers: [],
            options: []
        )
        let extendedCategory = UNNotificationCategory(
            identifier: Self.extendedCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([vibrationFinishCategory, extendedCategory])
    }

    /// Without this, a notification delivered while the app is foregrounded shows
    /// nothing at all (the system default). That silence is correct for a finish
    /// notification — the in-app UI already covers the foreground case — but wrong for
    /// the extend-awareness notification above, which has no in-app equivalent (nothing
    /// else tells a foregrounded-but-not-looking-at-this-timer user it just changed).
    /// Gated by category so finish/vibration-fallback notifications keep their existing
    /// silent-in-foreground behavior.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == Self.extendedCategoryID {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let id = response.notification.request.identifier
        guard response.notification.request.content.categoryIdentifier == NotificationScheduler.vibrationFinishCategoryID,
              let payload = TimerStore.loadAll().first(where: { $0.id == id }) else { return }

        switch response.actionIdentifier {
        case "STOP_ACTION":
            // Nothing is actively buzzing to interrupt — VibrationPlayer is
            // foreground-only, same as AlarmPlayer. "Stop" means "don't auto-buzz the
            // next time the app is opened/foregrounded for this finish."
            TimerStore.acknowledgeFinish(id: id)
        case "REPEAT_ACTION":
            // Same mutation sequence as ContentView.repeatTimer()/armAlerts: repeat,
            // save, reschedule, and (alarm is off here by construction — this category
            // only appears on a vibration-only notification) restart the custom Live
            // Activity too.
            let updated = payload.repeated()
            TimerStore.save(updated)
            AlarmController.reschedule(for: updated)
            LiveActivityController.start(for: updated)
            CloudSyncController.pushUp(updated, action: "repeated")
            WatchSyncController.pushCurrentState()
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        default:
            break
        }
    }
}
