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
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        content = request.content.mutableCopy() as? UNMutableNotificationContent
        guard CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) != nil else { return deliver() }

        let prior = Dictionary(TimerStore.loadAll().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        CloudSyncController.pullChanges(peek: true) { [weak self] updated, _ in
            guard let self else { return }
            // Only what actually changed here: an echo of this phone's own change, or a
            // record that's already stored as is, needs no new state.
            let changed = updated.filter { payload in
                guard let old = prior[payload.id] else { return true }
                return old.endDate != payload.endDate || old.pausedRemaining != payload.pausedRemaining
                    || old.label != payload.label || old.updatedAt != payload.updatedAt
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

    /// "Pasta" / "Sam paused" (+ "and 2 more"), from the record's last actor.
    private func describe(_ payload: TimerPayload?, more: Int) {
        guard let payload else { return deliver() }
        CloudSyncController.fetchAttribution(for: payload) { [weak self] attribution in
            guard let self, let content = self.content else { return }
            content.title = payload.label
            if let attribution {
                let phrase = CloudSyncController.attributionPhrase(name: attribution.name, action: attribution.action)
                content.body = more > 0 ? String(localized: "\(phrase) · \(more) more changed") : phrase
            }
            self.deliver()
        }
    }

    private func deliver() {
        guard let contentHandler, let content else { return }
        self.contentHandler = nil
        contentHandler(content)
    }

    /// Out of time (~30s): show what we have — the generic text if nothing resolved.
    override func serviceExtensionTimeWillExpire() {
        deliver()
    }
}
