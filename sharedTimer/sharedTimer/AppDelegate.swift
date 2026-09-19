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

        CloudSyncController.pullChanges { updated, deletedIDs in
            for payload in updated {
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

    // MARK: - Vibration-only finish notification actions

    /// Lock-screen "Repeat"/"Stop" for a vibration-only finish notification (alarm off
    /// — see `NotificationScheduler.vibrationFinishCategoryID`), the closest available
    /// parity with AlarmKit's panel for a payload AlarmKit never touches (AlarmKit only
    /// handles the alarm-on case). Neither action takes `.foreground` — both process
    /// silently without opening the app, which is the point.
    private func registerNotificationCategories() {
        let repeatAction = UNNotificationAction(identifier: "REPEAT_ACTION", title: "Repeat", options: [])
        let stopAction = UNNotificationAction(identifier: "STOP_ACTION", title: "Stop", options: [])
        let category = UNNotificationCategory(
            identifier: NotificationScheduler.vibrationFinishCategoryID,
            actions: [stopAction, repeatAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
