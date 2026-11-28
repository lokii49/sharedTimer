//
//  TimerTags.swift
//  Shared (app + Messages; excluded from the Clip, widget and notification service)
//
//  N5 (owner's picks 1A / 2A / on this phone only, 2026-11-27,
//  https://claude.ai/artifact/AgudcX6xN31JAZFxhNJerF): tags that filter the list and a
//  note per timer. Local to this iPhone, in the App Group — never in a share link,
//  iCloud, the Watch snapshot, widgets, Live Activities, Spotlight or Siri's TimerChoice.
//  Messages compiles this file only because the shared Edit sheet references it; it
//  doesn't show tags or notes (`EditTimerSheet.showsTagsAndNote`).
//
//  Tags have stable ids, so a rename is one write and a list filter survives it.
//

import Foundation
import SwiftUI

struct TimerTag: Codable, Identifiable, Hashable {
    let id: String
    var name: String
}

/// Everything N5 keeps, as one value (pure, so the rules are unit-testable).
struct TimerOrganizer: Codable, Equatable {
    var tags: [TimerTag] = []
    /// Timer id → tag ids, in the order tags were added.
    var tagsByTimer: [String: [String]] = [:]
    var notes: [String: String] = [:]
    /// Recents carry tags and notes (owner's call): what a timer of this name + length
    /// (RecentTimer.id) last had — kept for every name + length used, not just the six
    /// listed Recents — and which one each timer came from.
    struct Carried: Codable, Equatable {
        var tagIDs: [String] = []
        var note: String?
        /// When it was last used or changed, for the size cap.
        var usedAt: Date?
    }
    static let maxRemembered = 500
    var recentExtras: [String: Carried] = [:]
    var recentOf: [String: String] = [:]

    static let maxTagLength = 30
    static let maxNoteLength = 1_000

    init() {}

    // Lenient: a field this build can't read is dropped, never the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = (try? c.decodeIfPresent([TimerTag].self, forKey: .tags)) ?? []
        tagsByTimer = (try? c.decodeIfPresent([String: [String]].self, forKey: .tagsByTimer)) ?? [:]
        notes = (try? c.decodeIfPresent([String: String].self, forKey: .notes)) ?? [:]
        recentExtras = (try? c.decodeIfPresent([String: Carried].self, forKey: .recentExtras)) ?? [:]
        recentOf = (try? c.decodeIfPresent([String: String].self, forKey: .recentOf)) ?? [:]
    }

    func tags(for timerID: String) -> [TimerTag] {
        let ids = tagsByTimer[timerID] ?? []
        return ids.compactMap { id in tags.first { $0.id == id } }
    }

    func note(for timerID: String) -> String? { notes[timerID] }

    /// A new tag, or the existing one with the same name (case- and accent-blind).
    /// nil for an empty name.
    mutating func addTag(named raw: String) -> TimerTag? {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTagLength))
        guard !name.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return existing
        }
        let tag = TimerTag(id: UUID().uuidString, name: name)
        tags.append(tag)
        return tag
    }

    mutating func rename(tagID: String, to raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTagLength))
        guard !name.isEmpty, let index = tags.firstIndex(where: { $0.id == tagID }) else { return }
        tags[index].name = name
    }

    mutating func deleteTag(id tagID: String) {
        tags.removeAll { $0.id == tagID }
        for (key, carried) in recentExtras {
            recentExtras[key]?.tagIDs = carried.tagIDs.filter { $0 != tagID }
        }
        for (timer, ids) in tagsByTimer {
            let kept = ids.filter { $0 != tagID }
            tagsByTimer[timer] = kept.isEmpty ? nil : kept
        }
    }

    mutating func setTags(_ tagIDs: [String], for timerID: String) {
        let known = Set(tags.map(\.id))
        var seen = Set<String>()
        let kept = tagIDs.filter { known.contains($0) && seen.insert($0).inserted }
        tagsByTimer[timerID] = kept.isEmpty ? nil : kept
        remember(timerID)
    }

    mutating func toggle(tagID: String, for timerID: String) {
        var ids = tagsByTimer[timerID] ?? []
        if let index = ids.firstIndex(of: tagID) { ids.remove(at: index) } else { ids.append(tagID) }
        setTags(ids, for: timerID)
    }

    mutating func setNote(_ raw: String?, for timerID: String) {
        let note = raw.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNoteLength)) }
        notes[timerID] = (note?.isEmpty ?? true) ? nil : note
        remember(timerID)
    }

    /// A timer just started or recorded as the recent `key`: if it has tags or a note of
    /// its own (set in New Timer), the recent takes them; otherwise it gets the recent's
    /// (started again from a chip, Quick Action, Control Center or Siri).
    /// Merges: the new timer keeps what it was given (a tag preselected by the list
    /// filter, a note typed in New Timer) and fills the rest from what this name +
    /// length had — its tags join the given ones, its note fills an empty one. The
    /// result is then remembered.
    mutating func adopt(timerID: String, recentKey key: String, at date: Date = Date()) {
        recentOf[timerID] = key
        if let carried = recentExtras[key] {
            let known = Set(tags.map(\.id))
            var ids = tagsByTimer[timerID] ?? []
            for id in carried.tagIDs where known.contains(id) && !ids.contains(id) { ids.append(id) }
            tagsByTimer[timerID] = ids.isEmpty ? nil : ids
            if notes[timerID] == nil { notes[timerID] = carried.note }
        }
        remember(timerID, at: date)
    }

    /// Keeps the timer's recent in step with the timer's latest tags and note.
    private mutating func remember(_ timerID: String, at date: Date = Date()) {
        guard let key = recentOf[timerID] else { return }
        let carried = Carried(tagIDs: tagsByTimer[timerID] ?? [], note: notes[timerID], usedAt: date)
        recentExtras[key] = (carried.tagIDs.isEmpty && carried.note == nil) ? nil : carried
    }

    /// Drops tags and notes of timers no longer stored. Only with a complete store.
    /// Remembered name + length values are kept whether or not that timer is still in
    /// Recents; only past `maxRemembered`, the least recently used go.
    mutating func prune(keeping timerIDs: Set<String>) {
        tagsByTimer = tagsByTimer.filter { timerIDs.contains($0.key) }
        notes = notes.filter { timerIDs.contains($0.key) }
        recentOf = recentOf.filter { timerIDs.contains($0.key) }
        if recentExtras.count > Self.maxRemembered {
            let keep = recentExtras.sorted { ($0.value.usedAt ?? .distantPast) > ($1.value.usedAt ?? .distantPast) }
                .prefix(Self.maxRemembered).map(\.key)
            recentExtras = recentExtras.filter { Set(keep).contains($0.key) }
        }
    }

    /// The list filter: timers carrying `tagID` (all when nil or the tag is gone), and
    /// how many others there are.
    func filter(_ timers: [TimerPayload], tagID: String?) -> (shown: [TimerPayload], hidden: [TimerPayload]) {
        guard let tagID, tags.contains(where: { $0.id == tagID }) else { return (timers, []) }
        var shown: [TimerPayload] = [], hidden: [TimerPayload] = []
        for timer in timers {
            if tagsByTimer[timer.id]?.contains(tagID) == true { shown.append(timer) } else { hidden.append(timer) }
        }
        return (shown, hidden)
    }
}

enum TimerTagStore {
    static let changed = Notification.Name("SharedTimerTagsChanged")
    private static let key = "timerOrganizer.v1"
    private static let lock = NSLock()
    nonisolated(unsafe) static var defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lokesh.sharedTimer")

    static func load() -> TimerOrganizer {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Read-modify-write under one lock. A stored blob this build can't decode at all is
    /// left untouched (never overwritten with an empty one).
    static func update(_ change: (inout TimerOrganizer) -> Void) {
        lock.lock()
        if let data = defaults?.data(forKey: key), (try? JSONDecoder().decode(TimerOrganizer.self, from: data)) == nil {
            lock.unlock()
            return
        }
        var organizer = read()
        let before = organizer
        change(&organizer)
        if organizer != before, let data = try? JSONEncoder().encode(organizer) {
            defaults?.set(data, forKey: key)
        }
        lock.unlock()
        if organizer != before {
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }

    private static func read() -> TimerOrganizer {
        guard let data = defaults?.data(forKey: key) else { return TimerOrganizer() }
        return (try? JSONDecoder().decode(TimerOrganizer.self, from: data)) ?? TimerOrganizer()
    }
}

/// Tag chips for New Timer and Edit: tap to add or remove, "New Tag" makes one.
struct TagChipsPicker: View {
    @Binding var selection: [String]
    @State private var organizer = TimerTagStore.load()
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.subheadline)
            ChipFlowLayout(spacing: 8) {
                ForEach(organizer.tags) { tag in
                    let on = selection.contains(tag.id)
                    Button {
                        if on { selection.removeAll { $0 == tag.id } } else { selection.append(tag.id) }
                    } label: {
                        Text(tag.name)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? Color.white.opacity(0.9) : .white.opacity(0.14), in: Capsule())
                            .foregroundStyle(on ? Color.black : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("New Tag", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newTagButton")
            }
        }
        .padding(.vertical, 4)
        .alert("New Tag", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Add") {
                var made: TimerTag?
                TimerTagStore.update { made = $0.addTag(named: newName) }
                organizer = TimerTagStore.load()
                if let made, !selection.contains(made.id) { selection.append(made.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
