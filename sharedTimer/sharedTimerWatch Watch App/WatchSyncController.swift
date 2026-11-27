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
    /// Bumped by every applied phone context. A failed tap is rolled back only if no
    /// newer phone state arrived since it was sent: the phone's state is authoritative,
    /// and an Extend's optimistic result equals the phone's real one, so "still shows
    /// the optimistic state" alone can't tell a context that already carried the
    /// applied change from one that didn't (a late reply error undid a real +1:00).
    private(set) var contextGeneration = 0

    /// Per timer while taps await the phone: what to fall back to (the state before the
    /// first unacknowledged tap, moved forward as the phone acknowledges each) and the
    /// newest tap's optimistic state. Rolling a failed tap back to its own `before` was
    /// wrong once a second tap followed: Pause then Resume, both failing, ended on the
    /// first tap's "paused" while the phone was still running.
    private var inFlight: [String: (fallback: TimerPayload, latest: TimerPayload, count: Int)] = [:]

    func noteSent(id: String, before: TimerPayload, optimistic: TimerPayload) {
        if var entry = inFlight[id] {
            entry.latest = optimistic
            entry.count += 1
            inFlight[id] = entry
        } else {
            inFlight[id] = (before, optimistic, 1)
        }
    }

    func noteAcknowledged(id: String, optimistic: TimerPayload) {
        inFlight[id]?.fallback = optimistic
        settle(id)
    }

    private func settle(_ id: String) {
        guard var entry = inFlight[id] else { return }
        entry.count -= 1
        inFlight[id] = entry.count > 0 ? entry : nil
    }

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
    /// The tap's optimistic change, shown at once (and noted as in flight); nil for an
    /// unknown timer or op. Separate from the WatchConnectivity send so tests can drive it.
    @discardableResult
    func applyOptimistic(id: String, op: String) -> (before: TimerPayload, optimistic: TimerPayload)? {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return nil }
        let before = timers[index]
        switch op {
        case "pause": timers[index] = before.paused()
        case "resume": timers[index] = before.resumed()
        case "extend": timers[index] = before.extended(by: 60)
        default: return nil
        }
        persistSnapshot()
        noteSent(id: id, before: before, optimistic: timers[index])
        return (before, timers[index])
    }

    func send(id: String, op: String) {
        guard WCSession.default.activationState == .activated,
              let (before, optimistic) = applyOptimistic(id: id, op: op) else { return }
        // replyHandler must be non-nil, even though we ignore the payload: WCSession
        // routes a nil replyHandler to the phone's no-reply didReceiveMessage(_:) delegate
        // method, which WatchSyncController.SessionDelegate (phone side) doesn't implement
        // (only the replyHandler-taking variant) — confirmed via WCErrorCodeDeliveryFailed
        // in the phone's WCD logs ("delegate does not implement delegate method") when this
        // was nil. A real closure here selects the matching selector.
        let generation = contextGeneration
        WCSession.default.sendMessage(["id": id, "op": op], replyHandler: { [weak self] reply in
            // The phone rejected it (finished, scheduled, gone): undo. It also pushes
            // its real state, which lands separately.
            guard reply["ok"] as? Bool == false else {
                Task { @MainActor in self?.noteAcknowledged(id: id, optimistic: optimistic) }
                return
            }
            Task { @MainActor in self?.rollBack(id: id, to: before, ifStill: optimistic, sentAt: generation) }
        }) { [weak self] error in
            print("WatchSync: sendMessage(\(op)) failed: \(error)")
            Task { @MainActor in self?.rollBack(id: id, to: before, ifStill: optimistic, sentAt: generation) }
        }
    }

    /// Restores `before` only while no phone context arrived since the tap was sent and
    /// the timer still shows this tap's optimistic state — a newer phone state wins.
    /// With later taps in flight, "this tap's state" is the newest tap's, and the state
    /// to restore is the last one the phone acknowledged (see `inFlight`).
    func rollBack(id: String, to before: TimerPayload, ifStill optimistic: TimerPayload, sentAt generation: Int) {
        let target = inFlight[id]?.fallback ?? before
        let shown = inFlight[id]?.latest ?? optimistic
        defer { settle(id) }
        guard generation == contextGeneration,
              let i = timers.firstIndex(where: { $0.id == id }),
              timers[i].endDate == shown.endDate,
              timers[i].pausedRemaining == shown.pausedRemaining else { return }
        timers[i] = target
        persistSnapshot()
    }

    private func persistSnapshot() {
        if WatchTimerCache.save(timers, to: cacheDefaults) {
            WidgetCenter.shared.reloadTimelines(ofKind: "WatchTimerWidget")
        }
    }

    func apply(_ context: [String: Any]) {
        guard let data = context["timers"] as? Data,
              let decoded = try? JSONDecoder().decode([TimerPayload].self, from: data) else { return }
        contextGeneration += 1
        timers = decoded
        // The phone's state is now known: a later failed tap falls back to it, not to
        // a state from before a tap this context already reflects.
        for id in inFlight.keys {
            if let fresh = decoded.first(where: { $0.id == id }) { inFlight[id]?.fallback = fresh }
        }
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
