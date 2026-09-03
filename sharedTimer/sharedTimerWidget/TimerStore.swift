//
//  TimerStore.swift
//  sharedTimerWidget
//

import Foundation
import WidgetKit

/// `save`/`delete` reload every widget timeline as a side effect (see `persist`). Widget
/// extension code must only ever call `loadAll` — writing from inside a timeline provider
/// would trigger a reload from within that same reload's render pass.
enum TimerStore {
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "sharedTimers"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func save(_ payload: TimerPayload) {
        var all = loadAll()
        all.removeAll { $0.id == payload.id }
        all.append(payload)
        persist(all)
    }

    static func delete(id: String) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        persist(all)
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
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        return rawArray.compactMap { entry in
            guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? decoder.decode(TimerPayload.self, from: entryData)
        }
    }

    private static func persist(_ payloads: [TimerPayload]) {
        let cutoff = Date().addingTimeInterval(-86400)
        let trimmed = payloads.filter { $0.isPaused || $0.endDate > cutoff }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults?.set(data, forKey: key)
        // The home-screen widget only re-reads the App Group store when told to — otherwise
        // it keeps showing its last timeline entry until whatever refresh date it computed
        // last, which for a far-out countdown can be hours away.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
