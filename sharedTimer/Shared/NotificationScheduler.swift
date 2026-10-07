//
//  NotificationScheduler.swift
//  Shared
//

import Foundation
import UserNotifications

enum NotificationScheduler {
    /// Category for a vibration-only finish notification (alarm off, vibration on) —
    /// gives it lock-screen "Repeat"/"Stop" actions, the closest available parity with
    /// AlarmKit's panel for a payload AlarmKit never touches. Registered + handled in
    /// the main app's AppDelegate only (same target scope AlarmKit itself has); setting
    /// it in every target that compiles this is harmless — an unregistered category just renders with
    /// no action buttons, so Messages/Clip notifications degrade silently.
    static let vibrationFinishCategoryID = "SHAREDTIMER_VIBRATION_FINISH"

    /// Posted (main queue) whenever a schedule attempt finds notification permission
    /// denied, so a foreground surface can tell the person their backgrounded timers
    /// won't alert them — `requestAuthorization`'s `granted == false` case used to be
    /// swallowed silently here.
    static let permissionDeniedNotification = Notification.Name("SharedTimerNotificationPermissionDenied")

    /// Posts `permissionDeniedNotification` at most once per process — `scheduleAlert`
    /// runs once per active timer on every launch, and without this a screen full of
    /// timers would fire the same alert N times.
    private static var hasReportedDenial = false

    static let sequenceWindow = 8
    private static let schedulingLock = NSLock()
    private static var generations: [String: UUID] = [:]

    static func scheduleAlert(for payload: TimerPayload, excludingSequenceIndices: Set<Int> = [], excludingAnnualDates: Set<Date> = []) {
        cancel(id: payload.id)
        guard !payload.isPaused, !requests(for: payload, excludingSequenceIndices: excludingSequenceIndices, excludingAnnualDates: excludingAnnualDates).isEmpty else { return }
        let generation = UUID()
        schedulingLock.lock()
        generations[payload.id] = generation
        schedulingLock.unlock()
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
                schedule(payload, generation: generation, excludingSequenceIndices: excludingSequenceIndices, excludingAnnualDates: excludingAnnualDates, center: center)
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

    static func requestIDs(id: String) -> [String] {
        [id] + (0..<sequenceWindow).map { "\(id).phase.\($0)" }
    }

    static func cancel(id: String) {
        schedulingLock.lock()
        defer { schedulingLock.unlock() }
        generations.removeValue(forKey: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: requestIDs(id: id))
    }

    /// Fixed slots keep cancellation bounded even when the current phase changes.
    /// These requests work in Messages/Clip and as the main app's AlarmKit fallback.
    static func requests(for payload: TimerPayload, at date: Date = Date(), excludingSequenceIndices: Set<Int> = [], excludingAnnualDates: Set<Date> = []) -> [UNNotificationRequest] {
        let current = payload.advancedSequence(at: date)
        guard !current.isPaused else { return [] }
        let phases: [(SequencePhase, Date, Int?)]
        if let recurrence = current.recurrence {
            phases = current.upcomingAnnualDates(limit: 2, at: date).map {
                (SequencePhase(label: current.label, kind: .countdown, duration: current.duration,
                               alarmEnabled: current.alarmEnabled, vibrationEnabled: current.vibrationEnabled), $0, recurrence.year(of: $0))
            }
        } else if current.sequence != nil {
            phases = current.upcomingSequencePhases(limit: sequenceWindow).map { ($0.phase, $0.endDate, $0.globalIndex) }
        } else {
            phases = [(SequencePhase(label: current.label, kind: current.kind, duration: current.duration,
                                     alarmEnabled: current.alarmEnabled, vibrationEnabled: current.vibrationEnabled), current.endDate, nil)]
        }
        return phases.enumerated().compactMap { slot, occurrence in
            let (phase, end, index) = occurrence
            if current.recurrence != nil && excludingAnnualDates.contains(end) { return nil }
            if current.sequence != nil, let index, excludingSequenceIndices.contains(index) { return nil }
            let remaining = end.timeIntervalSince(date)
            guard remaining > 0 else { return nil }
            let content = UNMutableNotificationContent()
            content.title = phase.label
            content.body = current.recurrence != nil ? "Anniversary reached!" : index == nil ? (phase.kind == .countdown ? "Countdown complete!" : "Timer finished!") : "Sequence phase finished!"
            content.userInfo["timerID"] = current.id
            if let index { content.userInfo[current.recurrence != nil ? "annualYear" : "sequenceGlobalIndex"] = index }
            if phase.alarmEnabled {
                content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))
            } else if phase.vibrationEnabled {
                content.sound = nil
                content.categoryIdentifier = vibrationFinishCategoryID
            } else {
                content.sound = .default
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false)
            let identifier = index == nil ? current.id : "\(current.id).phase.\(slot)"
            return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }
    }

    private static func schedule(_ payload: TimerPayload, generation: UUID, excludingSequenceIndices: Set<Int>, excludingAnnualDates: Set<Date>, center: UNUserNotificationCenter) {
        let pending = requests(for: payload, excludingSequenceIndices: excludingSequenceIndices, excludingAnnualDates: excludingAnnualDates)
        schedulingLock.lock()
        defer { schedulingLock.unlock() }
        guard generations[payload.id] == generation else { return }
        for request in pending { center.add(request) }
    }
}
