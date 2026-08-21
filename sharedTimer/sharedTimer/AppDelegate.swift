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

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.registerForRemoteNotifications()
        CloudSyncController.registerSubscriptionsIfNeeded()
        WatchSyncController.activate()
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
                NotificationScheduler.cancel(id: payload.id)
                if payload.isPaused {
                    LiveActivityController.update(for: payload)
                } else {
                    NotificationScheduler.scheduleAlert(for: payload)
                    LiveActivityController.start(for: payload)
                }
            }
            for id in deletedIDs {
                TimerStore.delete(id: id)
                NotificationScheduler.cancel(id: id)
                LiveActivityController.end(id: id)
            }
            if !updated.isEmpty || !deletedIDs.isEmpty {
                WatchSyncController.pushCurrentState()
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
            }
            completionHandler(updated.isEmpty && deletedIDs.isEmpty ? .noData : .newData)
        }
    }
}
