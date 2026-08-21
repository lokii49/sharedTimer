//
//  WatchSyncController.swift
//  sharedTimerWatch Watch App
//
//  Watch-side half of the iPhone <-> Watch sync — see sharedTimer/WatchSyncController.swift
//  for the full rationale (App Groups don't cross devices; CloudKit-only misses unshared
//  timers). This is a thin mirror: `timers` reflects whatever the phone last pushed via
//  updateApplicationContext, and mutations relay back to the phone as a message rather
//  than being applied locally through any notification/Live Activity/CloudKit logic —
//  none of that exists on this target by design.
//

import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchSyncController: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncController()

    @Published private(set) var timers: [TimerPayload] = []

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// sendMessage requires the phone reachable right now — it does not queue. If it
    /// fails (phone out of Bluetooth/WiFi range), the optimistic update below has to be
    /// rolled back explicitly; otherwise the watch would silently show a state the phone
    /// never received until the next updateApplicationContext quietly overwrote it —
    /// the tap would visibly un-happen with no explanation in between.
    func send(id: String, op: String) {
        guard WCSession.default.activationState == .activated,
              let index = timers.firstIndex(where: { $0.id == id }) else { return }
        let before = timers[index]
        switch op {
        case "pause": timers[index] = before.paused()
        case "resume": timers[index] = before.resumed()
        case "extend": timers[index] = before.extended(by: 60)
        default: return
        }
        // replyHandler must be non-nil, even though we ignore the payload: WCSession
        // routes a nil replyHandler to the phone's no-reply didReceiveMessage(_:) delegate
        // method, which WatchSyncController.SessionDelegate (phone side) doesn't implement
        // (only the replyHandler-taking variant) — confirmed via WCErrorCodeDeliveryFailed
        // in the phone's WCD logs ("delegate does not implement delegate method") when this
        // was nil. A real closure here selects the matching selector.
        WCSession.default.sendMessage(["id": id, "op": op], replyHandler: { _ in }) { [weak self] error in
            print("WatchSync: sendMessage(\(op)) failed: \(error)")
            Task { @MainActor in
                guard let self, let i = self.timers.firstIndex(where: { $0.id == id }) else { return }
                self.timers[i] = before
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            print("WatchSync: activation failed: \(error)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["timers"] as? Data,
              let decoded = try? JSONDecoder().decode([TimerPayload].self, from: data) else { return }
        Task { @MainActor in
            WatchSyncController.shared.timers = decoded
        }
    }
}
