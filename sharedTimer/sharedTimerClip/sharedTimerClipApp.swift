//
//  sharedTimerClipApp.swift
//  sharedTimerClip
//

import SwiftUI
import UserNotifications

/// A tapped "time's up" notification can cold-launch the Clip with no link: remember
/// which timer it was for, so the Clip opens on it instead of the empty state.
final class ClipNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let opened = Notification.Name("ClipTimerNotificationOpened")
    /// Set by a tap that arrives before ContentView is listening (cold launch).
    nonisolated(unsafe) static var pendingTimerID: String?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["timerID"] as? String else { return }
        await MainActor.run {
            Self.pendingTimerID = id
            NotificationCenter.default.post(name: Self.opened, object: id)
        }
    }

    /// In front, the Clip's own loop is the alert — same as before it had a delegate.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

final class ClipAppDelegate: NSObject, UIApplicationDelegate {
    let notifications = ClipNotificationDelegate()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notifications
        return true
    }
}

@main
struct sharedTimerClipApp: App {
    @UIApplicationDelegateAdaptor(ClipAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // See sharedTimerApp.swift — Horizon is dark-first by design.
                .preferredColorScheme(.dark)
        }
    }
}
