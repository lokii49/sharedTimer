//
//  NotificationScheduler.swift
//  sharedTimerClip
//

import Foundation
import UserNotifications

enum NotificationScheduler {
    /// Posted (main queue) whenever a schedule attempt finds notification permission
    /// denied, so a foreground surface can tell the person their backgrounded timers
    /// won't alert them — `requestAuthorization`'s `granted == false` case used to be
    /// swallowed silently here.
    static let permissionDeniedNotification = Notification.Name("SharedTimerNotificationPermissionDenied")

    static func scheduleAlert(for payload: TimerPayload) {
        guard !payload.isPaused else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                print("SharedTimer notification permission denied — \(payload.label) won't alert in the background")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: permissionDeniedNotification, object: nil)
                }
                return
            }
            schedule(payload, center: center)
        }
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func schedule(_ payload: TimerPayload, center: UNUserNotificationCenter) {
        guard payload.remaining > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = payload.label
        content.body = payload.kind == .countdown ? "Countdown complete!" : "Timer finished!"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, payload.remaining), repeats: false)
        let request = UNNotificationRequest(identifier: payload.id, content: content, trigger: trigger)
        center.add(request)
    }
}
