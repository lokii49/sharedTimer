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
import WidgetKit

@MainActor
final class WatchSyncController: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSyncController()

    @Published private(set) var timers: [TimerPayload]
    private let cacheDefaults: UserDefaults?

    override convenience init() {
        self.init(defaults: WatchTimerCache.defaults)
    }

    init(defaults: UserDefaults?) {
        cacheDefaults = defaults
        timers = WatchTimerCache.load(from: defaults)
        super.init()
    }

    private var activationFailed = false

    func activate() {
        guard WCSession.isSupported() else { return }
        activationFailed = false
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Keep the SwiftUI background task alive until WCSession drains its delivery
    /// queue, then persist its latest context before watchOS suspends the app.
    func refreshInBackground() async {
        guard WCSession.isSupported() else { return }
        if WCSession.default.activationState != .activated { activate() }
        while !activationFailed && (WCSession.default.activationState != .activated || WCSession.default.hasContentPending) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return } // watchOS cancelled this background task.
        }
        guard !activationFailed, !Task.isCancelled else { return }
        apply(WCSession.default.receivedApplicationContext)
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
        persistSnapshot()
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
                self.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        if WatchTimerCache.save(timers, to: cacheDefaults) {
            WidgetCenter.shared.reloadTimelines(ofKind: "WatchTimerWidget")
        }
    }

    func apply(_ context: [String: Any]) {
        guard let data = context["timers"] as? Data,
              let decoded = try? JSONDecoder().decode([TimerPayload].self, from: data) else { return }
        timers = decoded
        persistSnapshot()
    }

    nonisolated private func receive(_ context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            print("WatchSync: activation failed: \(error)")
            Task { @MainActor in self.activationFailed = true }
        }
        if state == .activated { receive(session.receivedApplicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }
}
