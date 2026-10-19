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
        TimerSpotlightIndex.shared.start()
        // Ask for AlarmKit permission now so the prompt isn't racing the first
        // .timer's schedule call (see AlarmController).
        AlarmController.requestAuthorizationIfNeeded()
        registerNotificationCategories()
        UNUserNotificationCenter.current().delegate = self
        BackgroundRefresh.register()
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
            // iOS may suspend the app as soon as `completionHandler` runs, so every
            // alarm/notification change is awaited before it — a fire-and-forget
            // reschedule left a locked recipient's alarm at the old time.
            Task { @MainActor in
                for payload in updated {
                    TimerStore.save(payload)
                    // Same arming sequence as ContentView.armAlerts: AlarmKit alarm when
                    // either toggle is on (either kind), local notification only when both
                    // are off, and the custom Live Activity only for that both-off case
                    // (AlarmKit runs its own whenever it owns the alert).
                    await TimerArming.armAwaiting(payload)
                }
                for id in deletedIDs {
                    TimerStore.delete(id: id)
                    await AlarmController.clearAwaiting(id: id)
                    LiveActivityController.end(id: id)
                }
                if !updated.isEmpty || !deletedIDs.isEmpty {
                    WatchSyncController.pushCurrentState()
                    NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
                }
                // Who-did-what is the notification service extension's job now (the
                // visible CloudKit alert it rewrites); a second, app-posted "extended"
                // notice here duplicated it.
                completionHandler(updated.isEmpty && deletedIDs.isEmpty ? .noData : .newData)
            }
        }
    }

    // MARK: - Vibration-only finish notification actions

    /// Lock-screen "Repeat"/"Stop" for a vibration-only finish notification (alarm off
    /// — see `NotificationScheduler.vibrationFinishCategoryID`), the closest available
    /// parity with AlarmKit's panel for a payload AlarmKit never touches (AlarmKit only
    /// handles the alarm-on case). Neither action takes `.foreground` — both process
    /// silently without opening the app, which is the point.
    private func registerNotificationCategories() {
        let repeatAction = UNNotificationAction(identifier: "REPEAT_ACTION", title: String(localized: "Repeat"), options: [])
        let stopAction = UNNotificationAction(identifier: "STOP_ACTION", title: String(localized: "Stop"), options: [])
        let vibrationFinishCategory = UNNotificationCategory(
            identifier: NotificationScheduler.vibrationFinishCategoryID,
            actions: [stopAction, repeatAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([vibrationFinishCategory])
    }

    /// Without this, a notification delivered while the app is foregrounded shows
    /// nothing at all (the system default). That silence is right for a finish
    /// notification and for CloudKit's change alert — the in-app UI already shows both —
    /// so only the Control Center start confirmation gets a foreground banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == LiveActivityActions.startedCategoryID {
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
        let id = (response.notification.request.content.userInfo["timerID"] as? String) ?? response.notification.request.identifier
        guard response.notification.request.content.categoryIdentifier == NotificationScheduler.vibrationFinishCategoryID,
              let payload = TimerStore.loadAll().first(where: { $0.id == id }) else { return completionHandler() }

        switch response.actionIdentifier {
        case "STOP_ACTION":
            // Nothing is actively buzzing to interrupt — VibrationPlayer is
            // foreground-only, same as AlarmPlayer. "Stop" means "don't auto-buzz the
            // next time the app is opened/foregrounded for this finish."
            TimerStore.acknowledgeFinish(id: id)
            completionHandler()
        case "REPEAT_ACTION" where TimerStore.isReadOnly(id: id):
            // View-only share: Repeat would change it for everyone; just dismiss.
            completionHandler()
        case "REPEAT_ACTION":
            // Same mutation sequence as ContentView.repeatTimer()/armAlerts: repeat,
            // save, then TimerArming (AlarmKit if it's authorized by now, else the
            // notification fallback this category came from). Awaited before
            // `completionHandler`, which lets iOS suspend the app — same rule as the
            // push handler above.
            let updated = payload.repeated()
            TimerStore.save(updated)
            Task { @MainActor in
                await TimerArming.armAwaiting(updated)
                WatchSyncController.pushCurrentState()
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
                await CloudSyncController.pushUpAwaiting(updated, action: "repeated")
                completionHandler()
            }
        default:
            completionHandler()
        }
    }
}
