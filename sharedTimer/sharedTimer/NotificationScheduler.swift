//
//  NotificationScheduler.swift
//  sharedTimer
//

import Foundation
import UserNotifications

enum NotificationScheduler {
    /// Posted (main queue) whenever a schedule attempt finds notification permission
    /// denied, so a foreground surface can tell the person their backgrounded timers
    /// won't alert them — `requestAuthorization`'s `granted == false` case used to be
    /// swallowed silently here.
    static let permissionDeniedNotification = Notification.Name("SharedTimerNotificationPermissionDenied")

    /// Posts `permissionDeniedNotification` at most once per process — `scheduleAlert`
    /// runs once per active timer on every launch, and without this a screen full of
    /// timers would fire the same alert N times.
    private static var hasReportedDenial = false

    static func scheduleAlert(for payload: TimerPayload) {
        guard !payload.isPaused else { return }
        let center = UNUserNotificationCenter.current()
        // Check the *existing* status first: requestAuthorization's granted == false
        // covers both "already denied" and "just tapped Don't Allow on the prompt this
        // instant" — only the former should surface our own alert. Firing it the moment
        // someone answers the system prompt reads as arguing with their answer.
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                reportDenialOnce()
                return
            }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                schedule(payload, center: center)
            }
        }
    }

    private static func reportDenialOnce() {
        guard !hasReportedDenial else { return }
        hasReportedDenial = true
        print("SharedTimer notification permission denied — timers won't alert in the background")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: permissionDeniedNotification, object: nil)
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
        // Alarm on -> the same loud tone as the foreground loop. Alarm off (the
        // compose-sheet toggle) -> the standard notification sound, no "banging".
        content.sound = payload.alarmEnabled
            ? UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))
            : .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, payload.remaining), repeats: false)
        let request = UNNotificationRequest(identifier: payload.id, content: content, trigger: trigger)
        center.add(request)
    }
}
