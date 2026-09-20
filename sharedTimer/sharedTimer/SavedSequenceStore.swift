//
//  SavedSequenceStore.swift
//  sharedTimer
//

import Foundation

/// A reusable sequence blueprint — phases + loop count a user has chosen to keep for
/// starting again later, distinct from a running `TimerPayload.sequence` instance.
/// Main-app-only, same as sequences themselves (see CLAUDE.md): never carried through
/// `TimerPayload.url()`, CloudKit, or the watch app, so this file is intentionally not
/// duplicated into any other target.
struct SavedSequence: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var phases: [SequencePhase]
    var loopCount: Int

    init(id: String = UUID().uuidString, name: String, phases: [SequencePhase], loopCount: Int) {
        self.id = id
        self.name = name
        self.phases = phases
        self.loopCount = loopCount
    }
}

enum SavedSequenceStore {
    // Same App Group container `TimerStore` uses, under its own key — nothing else
    // reads this suite from a different target, but keeping all of this app's
    // persistence in one container avoids a stray `UserDefaults.standard` write that's
    // easy to lose track of later.
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "savedSequences"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func loadAll() -> [SavedSequence] {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedSequence].self, from: data) else {
            return []
        }
        return decoded
    }

    static func saveAll(_ sequences: [SavedSequence]) {
        guard let data = try? JSONEncoder().encode(sequences) else { return }
        defaults?.set(data, forKey: key)
    }
}
