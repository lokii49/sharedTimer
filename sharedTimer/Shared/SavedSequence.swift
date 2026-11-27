//
//  SavedSequence.swift
//  Shared
//
//  Saved sequence templates (app + Messages). Saving a template (`add`) stays in the
//  app's SavedSequenceStore.swift, since it also records a Recent.
//

import Foundation

/// A reusable sequence blueprint — phases + loop count a user has chosen to keep for
/// starting again later, distinct from a running `TimerPayload.sequence` instance.
/// Local to this iPhone: never carried through `TimerPayload.url()`, CloudKit, or the
/// watch app. Read by the app and, since 1.0.10, by Messages ("Your sequences", owner's
/// pick 2A) — excluded from the Clip, widget and notification service.
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

    // Decoded as a root array: a field added without a default would fail every entry.
    // New fields: `decodeIfPresent` + default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        phases = try container.decode([SequencePhase].self, forKey: .phases)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Sequence"
        loopCount = try container.decodeIfPresent(Int.self, forKey: .loopCount) ?? 1
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

    /// Falls back to entry-by-entry like `TimerStore.loadAll`, so one template this
    /// build can't read drops only itself instead of every saved template.
    static func loadAll() -> [SavedSequence] {
        guard let data = defaults?.data(forKey: key) else { return [] }
        if let decoded = try? JSONDecoder().decode([SavedSequence].self, from: data) {
            return decoded
        }
        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return rawArray.compactMap { entry in
            guard let dict = entry as? [String: Any],
                  let entryData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(SavedSequence.self, from: entryData)
        }
    }

    static func saveAll(_ sequences: [SavedSequence]) {
        guard let data = try? JSONEncoder().encode(sequences) else { return }
        defaults?.set(data, forKey: key)
    }
}

extension SavedSequence {
    /// A running sequence started from this template now — or nil when the template
    /// can't travel in a share link (no phases, or past the wire limits a local template
    /// isn't held to: 64 phases, 99 loops, 512-byte labels, 64 KiB), so Messages never
    /// sends a link the other side would reject.
    func shareablePayload() -> TimerPayload? {
        guard !phases.isEmpty else { return nil }
        let payload = TimerPayload.composeSequence(phases: phases, loopCount: loopCount)
        guard let decoded = TimerPayload.from(url: payload.url()), decoded.sequence?.phases.count == phases.count,
              decoded.sequence?.loopCount == payload.sequence?.loopCount else { return nil }
        return payload
    }
}
