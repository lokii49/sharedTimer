//
//  TimerStore.swift
//  sharedTimer
//

import Foundation
import WidgetKit

/// `save`/`delete` reload every widget timeline as a side effect (see `persist`). Widget
/// extension code must only ever call `loadAll` — writing from inside a timeline provider
/// would trigger a reload from within that same reload's render pass.
enum TimerStore {
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "sharedTimers"
    private static let acknowledgedFinishKey = "sharedTimerAcknowledgedFinishIDs"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func save(_ payload: TimerPayload) {
        var all = loadAll()
        all.removeAll { $0.id == payload.id }
        all.append(payload)
        persist(all)
        // Any prior "Stop" on this id was about the finish event it stopped — a fresh
        // mutation (repeat, extend past finish, a new share of the same id) means a
        // future finish should be free to alert again.
        clearAcknowledgedFinish(id: payload.id)
    }

    static func delete(id: String) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        persist(all)
        clearAcknowledgedFinish(id: id)
    }

    /// "Stop" tapped on the vibration-only finish notification (see AppDelegate's
    /// `UNUserNotificationCenterDelegate`) — there's nothing actively buzzing in the
    /// background to interrupt (`VibrationPlayer` is foreground-only), so "Stop" means
    /// "don't auto-buzz when the app is next opened/foregrounded for this finish."
    /// Checked by `AlarmController.shouldVibrateInApp`.
    static func acknowledgeFinish(id: String) {
        var ids = Set(defaults?.stringArray(forKey: acknowledgedFinishKey) ?? [])
        ids.insert(id)
        defaults?.set(Array(ids), forKey: acknowledgedFinishKey)
    }

    static func isFinishAcknowledged(id: String) -> Bool {
        (defaults?.stringArray(forKey: acknowledgedFinishKey) ?? []).contains(id)
    }

    private static func clearAcknowledgedFinish(id: String) {
        guard let ids = defaults?.stringArray(forKey: acknowledgedFinishKey), ids.contains(id) else { return }
        defaults?.set(ids.filter { $0 != id }, forKey: acknowledgedFinishKey)
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

    private static func persist(_ payloads: [TimerPayload]) {
        let cutoff = Date().addingTimeInterval(-86400)
        // A sequence-owning payload's raw `endDate` is only the CURRENT phase's — a
        // multi-day sequence not foregrounded in 24h+ would otherwise look
        // long-expired here even though later phases haven't run yet. Project it
        // forward first (pure/idempotent, doesn't mutate what's actually stored) so
        // the prune decision reflects whether the whole sequence is really done.
        let trimmed = payloads.filter {
            let projected = $0.sequence != nil ? $0.advancedSequence() : $0
            return projected.isPaused || projected.endDate > cutoff
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults?.set(data, forKey: key)
        // The home-screen widget only re-reads the App Group store when told to — otherwise
        // it keeps showing its last timeline entry until whatever refresh date it computed
        // last, which for a far-out countdown can be hours away.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
