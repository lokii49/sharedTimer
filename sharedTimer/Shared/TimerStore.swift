//
//  TimerStore.swift
//  Shared
//

import Foundation
import WidgetKit

/// `save`/`delete` reload every widget timeline as a side effect (see `persist`). Widget
/// extension code must only ever call `loadAll` — writing from inside a timeline provider
/// would trigger a reload from within that same reload's render pass.
enum TimerStore {
    /// Optional process-local observer installed only by the main app. Enqueue work
    /// here; callbacks run under the write lock and must never read/write the store.
    static var didPersist: (() -> Void)?

    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "sharedTimers"
    private static let acknowledgedFinishKey = "sharedTimerAcknowledgedFinishIDs"
    private static let alarmKitArmedKey = "sharedTimerAlarmKitArmedIDs"
    private static let readOnlyKey = "sharedTimerReadOnlyIDs"
    private static let widgetFocusKey = "sharedTimerWidgetFocusID"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// True once any timer was ever saved on this install (the key stays, as `[]`, after
    /// every timer is deleted) — tells an update from a fresh install for What's New.
    static var hasStoredData: Bool {
        defaults?.object(forKey: key) != nil
    }

    static func save(_ payload: TimerPayload) {
        withWriteLock {
            var all = loadAll()
            let prior = all.first { $0.id == payload.id }
            all.removeAll { $0.id == payload.id }
            all.append(Self.keepingExtraTime(of: prior, in: payload))
            persist(all)
            // Any prior "Stop" on this id was about the finish event it stopped — a
            // mutation that moves that finish (repeat, extend past finish, resume) means
            // a future finish should be free to alert again. A save that leaves the
            // finish where it was (a CloudKit echo of this device's own Stop, a rename)
            // must keep the Stop, or the app re-alerts on next open. 1s absorbs the
            // CloudKit Date round-trip.
            if finishMoved(from: prior, to: payload) {
                clearAcknowledgedFinish(id: payload.id)
            }
        }
    }

    static func delete(id: String) {
        withWriteLock {
            var all = loadAll()
            all.removeAll { $0.id == id }
            persist(all)
            clearAcknowledgedFinish(id: id)
            updateIDSet(alarmKitArmedKey, id: id, member: false)
            updateIDSet(readOnlyKey, id: id, member: false)
        }
    }

    /// Every read-modify-write of this store runs under an exclusive `flock` on a
    /// lock file in the App Group container. The app, the Messages extension, the
    /// App Clip and in-app intents can all write concurrently (separate processes,
    /// or separate threads of one), and an unguarded load → mutate → persist let one
    /// writer silently drop another's change. Not re-entrant: helpers called from
    /// inside (`clearAcknowledgedFinish`, `updateIDSet`) never take it themselves.
    /// Falls back to running unlocked if the container is unavailable. Readers
    /// (`loadAll`, the widget) don't lock — each `set` of a key is atomic already.
    private static func withWriteLock(_ body: () -> Void) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("TimerStore.lock") else { return body() }
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        // A signal can interrupt the wait; retry rather than run unlocked.
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        defer { flock(fd, LOCK_UN) }
        body()
    }

    /// Adds/removes `id` in a string-set key. Caller holds the write lock.
    private static func updateIDSet(_ key: String, id: String, member: Bool) {
        var ids = Set(defaults?.stringArray(forKey: key) ?? [])
        let changed = member ? ids.insert(id).inserted : ids.remove(id) != nil
        guard changed else { return }
        defaults?.set(Array(ids), forKey: key)
    }

    /// Ids with a current or upcoming sequence-phase alert armed through AlarmKit.
    /// Written only by `AlarmController` (main app — AlarmKit itself is unavailable in
    /// extensions); read by the Messages extension and App Clip, which can't see
    /// AlarmKit's own state. Opening a shared timer there must not arm a second
    /// notification + custom Live Activity on top of the main app's AlarmKit alarm
    /// (double alert, and the "too many Live Activities" bug). Plain App Group data, no
    /// AlarmKit import — this file still compiles into the Widget.
    static func setAlarmKitArmed(id: String, _ armed: Bool) {
        withWriteLock { updateIDSet(alarmKitArmedKey, id: id, member: armed) }
    }

    /// The timer the user last acted on from a widget / Live Activity button. An
    /// unconfigured Single Timer widget keeps showing it even once paused or finished,
    /// so Resume / Repeat stay on screen right where they tapped — otherwise the widget
    /// jumped to another timer, or to "No Timers", the moment they hit Pause.
    /// Written by the app (LiveActivityActions); read by the widget.
    static func setWidgetFocus(id: String) {
        defaults?.set(id, forKey: widgetFocusKey)
    }

    static var widgetFocusID: String? {
        defaults?.string(forKey: widgetFocusKey)
    }

    static func isAlarmKitArmed(id: String) -> Bool {
        (defaults?.stringArray(forKey: alarmKitArmedKey) ?? []).contains(id)
    }

    /// Shared with this device as "view only" (the owner's choice in Manage Sharing,
    /// enforced by CloudKit's server). Every mutation entry point — app, Messages, Siri,
    /// Live Activity/widget buttons, Watch relay, notification actions — checks this and
    /// offers only silence/remove. In TimerStore, not CloudLink, so the widget (which
    /// can't see CloudLink) can hide its buttons too. Written by CloudSyncController.
    static func setReadOnly(id: String, _ readOnly: Bool) {
        guard isReadOnly(id: id) != readOnly else { return }
        withWriteLock { updateIDSet(readOnlyKey, id: id, member: readOnly) }
        // The widgets show or hide their buttons by this; they only re-read when told.
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func isReadOnly(id: String) -> Bool {
        (defaults?.stringArray(forKey: readOnlyKey) ?? []).contains(id)
    }

    /// "Stop" tapped on the vibration-only finish notification (see AppDelegate's
    /// `UNUserNotificationCenterDelegate`) — there's nothing actively buzzing in the
    /// background to interrupt (`VibrationPlayer` is foreground-only), so "Stop" means
    /// "don't auto-buzz when the app is next opened/foregrounded for this finish."
    /// Checked by `AlarmController.shouldVibrateInApp`.
    static func acknowledgeFinish(id: String) {
        withWriteLock { updateIDSet(acknowledgedFinishKey, id: id, member: true) }
    }

    static func isFinishAcknowledged(id: String) -> Bool {
        (defaults?.stringArray(forKey: acknowledgedFinishKey) ?? []).contains(id)
    }

    /// CloudKit records don't carry `extraTime`, so a pulled copy arrives with 0. When it
    /// describes the same run as the stored copy (same length and end — this device's
    /// own change echoing back), keep the stored extends so the ring
    /// doesn't jump back to full.
    static func keepingExtraTime(of prior: TimerPayload?, in payload: TimerPayload) -> TimerPayload {
        guard payload.extraTime == 0, let prior, prior.extraTime > 0, prior.duration == payload.duration,
              prior.isPaused == payload.isPaused else { return payload }
        let sameRun = payload.isPaused
            ? abs((prior.pausedRemaining ?? 0) - (payload.pausedRemaining ?? 0)) < 1
            : abs(prior.endDate.timeIntervalSince(payload.endDate)) < 1
        guard sameRun else { return payload }
        var copy = payload
        copy.extraTime = prior.extraTime
        return copy
    }

    static func finishMoved(from prior: TimerPayload?, to payload: TimerPayload) -> Bool {
        guard let prior else { return true }
        return abs(prior.endDate.timeIntervalSince(payload.endDate)) >= 1 || prior.isPaused != payload.isPaused
    }

    /// Caller holds the write lock.
    private static func clearAcknowledgedFinish(id: String) {
        updateIDSet(acknowledgedFinishKey, id: id, member: false)
    }

    static func loadAll() -> [TimerPayload] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        // Whole-array decode first: cheap, and covers every payload written by this
        // build. Falls back to decoding entry-by-entry only if that fails, so one
        // payload a future schema change can't parse drops just itself instead of
        // wiping every timer in the store.
        if let decoded = try? JSONDecoder().decode([TimerPayload].self, from: data) {
            return decoded
        }
        // Cast to [Any] first, not [[String: Any]] directly — a wrong-typed element
        // (not even an object) would fail that cast for the whole array and fall
        // straight back to the wipe this function exists to avoid.
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        let decoder = JSONDecoder()
        return rawArray.compactMap { entry -> TimerPayload? in
            guard let dict = entry as? [String: Any],
                  let entryData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(TimerPayload.self, from: entryData)
        }
    }

    private static func undecodableEntries(excluding ids: Set<String>) -> [Any] {
        guard let data = defaults?.data(forKey: key),
              (try? JSONDecoder().decode([TimerPayload].self, from: data)) == nil,
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return rawArray.filter { entry in
            guard let dict = entry as? [String: Any] else { return false }
            if let id = dict["id"] as? String, ids.contains(id) { return false }
            guard let entryData = try? JSONSerialization.data(withJSONObject: dict) else { return false }
            return (try? decoder.decode(TimerPayload.self, from: entryData)) == nil
        }
    }

    private static func persist(_ payloads: [TimerPayload]) {
        let cutoff = Date().addingTimeInterval(-86400)
        // A sequence-owning payload's raw `endDate` is only the CURRENT phase's — a
        // multi-day sequence not foregrounded in 24h+ would otherwise look
        // long-expired here even though later phases haven't run yet. Project it
        // forward first (pure/idempotent, doesn't mutate what's actually stored) so
        // the prune decision reflects whether the whole sequence is really done.
        let trimmed = payloads.filter {
            let projected = $0.advancedSequence()
            return projected.isPaused || projected.endDate > cutoff
        }
        guard var data = try? JSONEncoder().encode(trimmed) else { return }
        // Entries this build can't decode (written by a newer version, say) were left out
        // of `payloads` by loadAll; writing without them deleted those timers for good.
        // Carry them over untouched, unless a decodable payload now has the same id.
        let undecodable = undecodableEntries(excluding: Set(trimmed.map(\.id)))
        if !undecodable.isEmpty,
           let encoded = try? JSONSerialization.jsonObject(with: data) as? [Any],
           let merged = try? JSONSerialization.data(withJSONObject: encoded + undecodable) {
            data = merged
        }
        defaults?.set(data, forKey: key)
        // The home-screen widget only re-reads the App Group store when told to — otherwise
        // it keeps showing its last timeline entry until whatever refresh date it computed
        // last, which for a far-out countdown can be hours away.
        WidgetCenter.shared.reloadAllTimelines()
        didPersist?()
    }
}
