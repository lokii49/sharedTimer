//
//  SavedSequenceStore.swift
//  sharedTimer
//

import Foundation

/// A reusable sequence blueprint — phases + loop count a user has chosen to keep for
/// starting again later, distinct from a running `TimerPayload.sequence` instance.
/// Main-app-only, same as sequences themselves (see CLAUDE.md): never carried through
/// `TimerPayload.url()`, CloudKit, or the watch app, so this file intentionally lives in
/// sharedTimer/, not in Shared/.
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

    /// Keeps a running sequence (e.g. one received in Messages) as a template. Only the
    /// blueprint is stored — phases and loop count — never the running position.
    static func add(_ sequence: SequenceInfo, name: String) {
        guard !contains(sequence) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedSequence(name: trimmed.isEmpty ? suggestedName(for: sequence) : trimmed,
                                  phases: sequence.phases, loopCount: sequence.loopCount)
        saveAll(loadAll() + [saved])
    }

    static func contains(_ sequence: SequenceInfo) -> Bool {
        loadAll().contains { $0.phases == sequence.phases && $0.loopCount == sequence.loopCount }
    }

    /// "Focus + Break" for a two-phase sequence, the first label for longer ones.
    static func suggestedName(for sequence: SequenceInfo) -> String {
        let labels = sequence.phases.map(\.label)
        if labels.count == 2 { return labels.joined(separator: " + ") }
        return labels.first.map { "\($0) sequence" } ?? "Sequence"
    }
}
