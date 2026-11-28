//
//  SavedSequenceStore.swift
//  sharedTimer
//
//  The app-only half of SavedSequenceStore (Shared/SavedSequence.swift): saving a
//  template, which also records it as a Recent (RecentTimersStore is app + widget only).
//

import Foundation

extension SavedSequenceStore {
    /// Keeps a running sequence (e.g. one received in Messages) as a template. Only the
    /// blueprint is stored — phases and loop count — never the running position.
    static func add(_ sequence: SequenceInfo, name: String) {
        guard !contains(sequence) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedSequence(name: trimmed.isEmpty ? suggestedName(for: sequence) : trimmed,
                                  phases: sequence.phases, loopCount: sequence.loopCount)
        saveAll(loadAll() + [saved])
        // A just-saved template is one tap away in Recent (D5 · A).
        RecentTimersStore.record(sequence: sequence, name: saved.name)
        RecentTimersSync.refresh()
    }

    static func contains(_ sequence: SequenceInfo) -> Bool {
        loadAll().contains { $0.phases == sequence.phases && $0.loopCount == sequence.loopCount }
    }

    /// "Focus + Break" for a two-phase sequence, the first label for longer ones.
    static func suggestedName(for sequence: SequenceInfo) -> String {
        let labels = sequence.phases.map(\.label)
        if labels.count == 2 { return labels.joined(separator: " + ") }
        return labels.first.map { String(localized: "\($0) sequence") } ?? String(localized: "Sequence")
    }
}
