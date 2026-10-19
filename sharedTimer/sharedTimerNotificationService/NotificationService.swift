//
//  NotificationService.swift
//  sharedTimerNotificationService
//
//  Runs when CloudKit's "A shared timer changed." alert arrives (see
//  CloudSyncController.registerSubscriptionsIfNeeded), even if the app was swiped away.
//  It peeks at the change (never moving a change token — the app's own pull must still
//  see it to re-arm AlarmKit), rewrites the banner ("Sam paused Pasta"), stores the new
//  state for the widgets/Messages, and moves this phone's quiet notification alerts.
//
//  It can't touch AlarmKit or Live Activities (iOS doesn't allow it in extensions):
//  those catch up when the app wakes, which this visible push makes far more likely.
//  Not a user mutation: no CloudKit push, no `updatedAt` stamp, no deletions.
//

import CloudKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    // The system may call serviceExtensionTimeWillExpire on another thread while a
    // CloudKit callback is still writing: every touch of these goes through `lock`.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        content?.body = CloudSyncController.changeAlertText
        lock.withLock {
            self.contentHandler = contentHandler
            self.content = content
        }
        guard CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) != nil else { return deliver() }

        let prior = Dictionary(TimerStore.loadAll().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        CloudSyncController.pullChanges(peek: true) { [weak self] updated, _ in
            guard let self else { return }
            // Only what actually changed here. CloudKit keeps dates to the millisecond,
            // so compare with a tolerance — an echo of this phone's own change, or a
            // record already stored as is, is not news.
            let changed = updated.filter { payload in
                guard let old = prior[payload.id] else { return true }
                return Self.differs(old.endDate, payload.endDate) || Self.differs(old.updatedAt, payload.updatedAt)
                    || old.isPaused != payload.isPaused || old.label != payload.label
            }
            for payload in changed {
                TimerStore.save(payload)
                guard !TimerStore.isAlarmKitArmed(id: payload.id) else { continue }
                NotificationScheduler.cancel(id: payload.id)
                if !payload.isPaused && !payload.isExpired { NotificationScheduler.scheduleAlert(for: payload) }
            }
            self.describe(changed.first, more: changed.count - 1)
        }
    }

    private static func differs(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return abs(a.timeIntervalSince(b)) >= 1
        case (nil, nil): return false
        default: return true
        }
    }

    /// "Pasta" / "Sam paused" (+ "and 2 more"), from the record's last actor. Nothing to
    /// describe, or this phone's own change: keep the generic text, and quietly — an
    /// extension can't drop a notification without an Apple-granted entitlement.
    private func describe(_ payload: TimerPayload?, more: Int) {
        guard let payload else { return quiet() }
        CloudSyncController.fetchAttribution(for: payload) { [weak self] attribution in
            guard let self else { return }
            if let attribution, attribution.name == DisplayNameStore.name { return self.quiet() }
            self.lock.withLock {
                guard let content = self.content else { return }
                content.title = payload.label
                if let attribution {
                    let phrase = CloudSyncController.attributionPhrase(name: attribution.name, action: attribution.action)
                    content.body = more > 0 ? String(localized: "\(phrase) · \(more) more changed") : phrase
                }
            }
            self.deliver()
        }
    }

    private func quiet() {
        lock.withLock {
            content?.sound = nil
            content?.interruptionLevel = .passive
        }
        deliver()
    }

    /// Calls the content handler exactly once, whichever path gets here first.
    private func deliver() {
        let handoff: (((UNNotificationContent) -> Void), UNNotificationContent)? = lock.withLock {
            guard let contentHandler, let content else { return nil }
            self.contentHandler = nil
            return (contentHandler, content.copy() as! UNNotificationContent)
        }
        if let (handler, content) = handoff { handler(content) }
    }

    /// Out of time (~30s): show what we have — the generic text if nothing resolved.
    override func serviceExtensionTimeWillExpire() {
        deliver()
    }
}
