//
//  NotificationScheduler.swift
//  sharedTimerMessages
//

import Foundation
import UserNotifications

enum NotificationScheduler {
    static func scheduleAlert(for payload: TimerPayload) {
        guard !payload.isPaused else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
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
        content.body = "Timer finished!"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, payload.remaining), repeats: false)
        let request = UNNotificationRequest(identifier: payload.id, content: content, trigger: trigger)
        center.add(request)
    }
}
