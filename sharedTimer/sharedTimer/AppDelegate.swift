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

        // Snapshot before any of this batch's saves land — compared per-payload below to
        // tell a genuine incoming extend from this device's own change echoing back
        // through the same silent-push subscription (TimerStore.save already ran before
        // ContentView.apply's CloudSyncController.pushUp, so a self-echo's endDate always
        // matches what's already here and the delta is zero).
        let priorState = Dictionary(uniqueKeysWithValues: TimerStore.loadAll().map { ($0.id, $0) })

        CloudSyncController.pullChanges { updated, deletedIDs in
            // iOS may suspend the app as soon as `completionHandler` runs, so every
            // alarm/notification change is awaited before it — a fire-and-forget
            // reschedule left a locked recipient's alarm at the old time.
            Task { @MainActor in
                var extended: [(existing: TimerPayload, updated: TimerPayload)] = []
                for payload in updated {
                    TimerStore.save(payload)
                    // Same arming sequence as ContentView.armAlerts: AlarmKit alarm when
                    // either toggle is on (either kind), local notification only when both
                    // are off, and the custom Live Activity only for that both-off case
                    // (AlarmKit runs its own whenever it owns the alert).
                    await TimerArming.armAwaiting(payload)
                    if let existing = priorState[payload.id] {
                        extended.append((existing, payload))
                    }
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
                // One deadline for the whole batch, so several extends while CloudKit is
                // unreachable can't stack past the background budget.
                let deadline = Date().addingTimeInterval(8)
                for change in extended {
                    await self.notifyIfExtended(existing: change.existing, updated: change.updated, deadline: deadline)
                }
                completionHandler(updated.isEmpty && deletedIDs.isEmpty ? .noData : .newData)
            }
        }
    }

    // MARK: - "Someone extended your timer" notification

    /// Category for the extend-awareness notification below — used only to opt it into
    /// a foreground banner (see `willPresent`); it carries no actions.
    private static let extendedCategoryID = "SHAREDTIMER_TIMER_EXTENDED"

    /// Posts a local, user-visible notification when a shared timer/countdown someone
    /// else is looking at was just extended — the silent CloudKit push that applies the
    /// change otherwise has zero visible signal, so the other participant would only
    /// find out by happening to reopen the app. Scoped deliberately narrow: only a pure
    /// extend (`endDate` moved forward, `duration`/pause state unchanged, the payload
    /// was actively running, not finished) triggers this — pause/resume fire far more
    /// often and would make this noisy, and a repeat looks superficially similar (its
    /// `endDate` also jumps forward) but always starts from a finished payload, which
    /// `existing.remaining > 0` excludes.
    private func notifyIfExtended(existing: TimerPayload, updated: TimerPayload, deadline: Date) async {
        let delta = updated.endDate.timeIntervalSince(existing.endDate)
        guard !existing.isPaused, !updated.isPaused,
              existing.duration == updated.duration,
              existing.remaining > 0,
              delta >= 5,
              // "Next" between two equal-length phases has the same shape.
              existing.sequence?.phaseIndex == updated.sequence?.phaseIndex,
              existing.sequence?.loopIndex == updated.sequence?.loopIndex else { return }

        let attribution = await Self.attribution(for: updated, timeout: max(0, deadline.timeIntervalSinceNow))
        // A pause then resume before this push lands also moves endDate forward with
        // nothing else changed; the record's last action tells them apart. Without it
        // (timeout, older record) fall back to the shape check above.
        if let attribution, attribution.action != "extended" { return }
        let who = attribution?.name ?? String(localized: "Someone")
        let content = UNMutableNotificationContent()
        content.title = updated.label
        content.body = String(localized: "\(who) added \(Self.deltaText(delta)) — now ends at \(updated.endDate.formatted(date: .omitted, time: .shortened))")
        content.sound = .default
        content.categoryIdentifier = Self.extendedCategoryID
        // A fresh identifier per extend (not e.g. `updated.id` alone) so a second
        // extend before the first notification is seen adds rather than replaces —
        // each one is real, distinct news.
        let request = UNNotificationRequest(
            identifier: "\(updated.id)-extended-\(Int(updated.endDate.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// `fetchAttribution` is a CloudKit fetch with no timeout of its own; a background
    /// push gets ~30s in total, so fall back to "Someone" rather than miss the banner.
    private static func attribution(for payload: TimerPayload, timeout: TimeInterval) async -> (name: String, action: String)? {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            CloudSyncController.fetchAttribution(for: payload) { attribution in
                if once.claim() { continuation.resume(returning: attribution) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// First caller wins — guards a continuation against the fetch and the timeout both
    /// resuming it.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    private static func deltaText(_ interval: TimeInterval) -> String {
        // Localized unit names ("5 min", "5 Min.", "5 分钟").
        Duration.seconds(Int(interval.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
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
        let extendedCategory = UNNotificationCategory(
            identifier: Self.extendedCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([vibrationFinishCategory, extendedCategory])
    }

    /// Without this, a notification delivered while the app is foregrounded shows
    /// nothing at all (the system default). That silence is correct for a finish
    /// notification — the in-app UI already covers the foreground case — but wrong for
    /// the extend-awareness notification above, which has no in-app equivalent (nothing
    /// else tells a foregrounded-but-not-looking-at-this-timer user it just changed).
    /// Gated by category so finish/vibration-fallback notifications keep their existing
    /// silent-in-foreground behavior.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if [Self.extendedCategoryID, LiveActivityActions.startedCategoryID].contains(notification.request.content.categoryIdentifier) {
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
