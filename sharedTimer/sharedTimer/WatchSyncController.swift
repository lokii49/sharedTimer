//
//  WatchSyncController.swift
//  sharedTimer
//
//  iPhone <-> Watch sync via WatchConnectivity — see CLAUDE.md's Phase 3 (watch) plan.
//  App Groups do NOT sync across physical devices (iPhone and Watch have separate
//  container filesystems, even though "paired") — verified against Apple's own guidance
//  before writing this, not assumed. CloudKit alone was also rejected: most timers are
//  never shared, so they never get a CloudLink and never reach CloudKit at all (see
//  CloudSyncController.swift's own documented behavior) — a CloudKit-only watch app would
//  show nothing for someone who's never shared a timer.
//
//  So the watch is a thin mirror of this device's full local TimerStore, kept in sync via
//  WCSession's application context (replaces-not-queues, delivered on the watch's next
//  wake). Mutations initiated on the watch relay back here as a message and are applied
//  through the exact same TimerStore/NotificationScheduler/LiveActivityController/
//  CloudSyncController sequence every other surface uses — the watch never touches any of
//  those directly (ActivityKit isn't even available on watchOS).
//
//  Same invariant as CloudSyncController.swift: push is an explicit, separate call at
//  each mutation call site (ContentView.apply()/delete()/pullCloudChanges(),
//  AppDelegate's push handler), never folded into TimerStore.save() itself — TimerStore
//  is shared into the Widget target, which must never gain a network/IPC side effect from
//  a timeline-provider render pass.
//
//  Main app target only — the watch has no companion process of its own to run a second
//  WCSession from, so a mutation made in the Messages extension or via a Siri intent while
//  this app is fully backgrounded won't reach the watch until this app is next
//  foregrounded. Same shape as the existing CloudKit-push limitation already documented
//  for the Messages extension.
//

import Foundation
import WatchConnectivity

enum WatchSyncController {
    private static let session = WCSession.default
    private static let delegate = SessionDelegate()

    static func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = delegate
        session.activate()
    }

    /// Fire-and-forget snapshot push — call after every local TimerStore change.
    /// updateApplicationContext replaces any pending context rather than queuing, so a
    /// burst of calls collapses to the latest state.
    static func pushCurrentState() {
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let payloads = TimerStore.loadAll()
        guard let data = try? JSONEncoder().encode(payloads) else { return }
        do {
            try session.updateApplicationContext(["timers": data])
        } catch {
            log("pushCurrentState failed: \(error)")
        }
    }

    private class SessionDelegate: NSObject, WCSessionDelegate {
        func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
            if let error {
                log("activation failed: \(error)")
            } else if state == .activated {
                pushCurrentState()
            }
        }

        func sessionDidBecomeInactive(_ session: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) { session.activate() }

        /// A mutation relayed from the watch. Applied independently of ContentView — same
        /// pattern AppDelegate's silent-push handler already uses — through the exact
        /// same static calls every other surface uses, so it schedules
        /// notifications/Live Activity/CloudKit push identically. ContentView picks up
        /// the result on next foreground via its scenePhase reload (reads
        /// TimerStore.loadAll() there).
        func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
            // WCSessionDelegate callbacks land on a background queue — every other
            // async-callback path here hops to main before touching TimerStore/
            // NotificationScheduler/LiveActivityController (see ContentView.
            // pullCloudChanges, MessagesViewController.acceptShareIfNeeded); this one
            // needs the same hop, not least because LiveActivityController.start's
            // Activity.request and TimerStore.persist's WidgetCenter.reloadAllTimelines
            // both assume it.
            DispatchQueue.main.async {
                guard let id = message["id"] as? String, let op = message["op"] as? String else {
                    replyHandler([:]); return
                }
                let all = TimerStore.loadAll()
                guard let existing = all.first(where: { $0.id == id }) else { replyHandler([:]); return }
                let action: String
                let updated: TimerPayload
                switch op {
                case "pause": updated = existing.paused(); action = "paused"
                case "resume": updated = existing.resumed(); action = "resumed"
                case "extend": updated = existing.extended(by: 60); action = "extended"
                default: replyHandler([:]); return
                }
                TimerStore.save(updated)
                NotificationScheduler.cancel(id: updated.id)
                if updated.isPaused {
                    LiveActivityController.update(for: updated)
                } else {
                    NotificationScheduler.scheduleAlert(for: updated)
                    LiveActivityController.start(for: updated)
                }
                CloudSyncController.pushUp(updated, action: action)
                pushCurrentState()
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
                replyHandler(["ok": true])
            }
        }
    }

    private static func log(_ message: String) {
        print("WatchSync: \(message)")
    }
}

/// Posted whenever a mutation lands on this device from outside ContentView's own
/// apply()/delete() calls (watch relay here; AppDelegate's CloudKit silent-push handler
/// too) — ContentView's `timers` is a local @State array with no other way to learn
/// TimerStore changed while the app is already foregrounded (scenePhase only fires on
/// background<->active transitions, not while staying active).
extension Notification.Name {
    static let externalTimerStoreChange = Notification.Name("externalTimerStoreChange")
}
