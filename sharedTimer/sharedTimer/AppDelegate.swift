//
//  AppDelegate.swift
//  sharedTimer
//
//  The first AppDelegate this project has needed — exists solely to receive silent
//  CloudKit push (see CloudSyncController) and apply the resulting changes through the
//  same TimerStore/NotificationScheduler/LiveActivityController call sequence every
//  other mutation path already uses. Plugged into the otherwise pure-SwiftUI app
//  lifecycle via `@UIApplicationDelegateAdaptor` in sharedTimerApp.swift — no scene
//  delegate needed, since share ACCEPTANCE happens via our own universal link
//  (CloudSyncController.acceptShare), not via `userDidAcceptCloudKitShareWith`.
//

import CloudKit
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.registerForRemoteNotifications()
        CloudSyncController.registerSubscriptionsIfNeeded()
        return true
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
            completionHandler(updated.isEmpty && deletedIDs.isEmpty ? .noData : .newData)
        }
    }
}
