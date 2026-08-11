//
//  TimerStore.swift
//  sharedTimerClip
//

import Foundation

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
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TimerPayload].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func persist(_ payloads: [TimerPayload]) {
        let cutoff = Date().addingTimeInterval(-86400)
        let trimmed = payloads.filter { $0.isPaused || $0.endDate > cutoff }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults?.set(data, forKey: key)
    }
}
