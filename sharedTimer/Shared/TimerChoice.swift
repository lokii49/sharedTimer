// Shared by Siri/Shortcuts and the single-timer widget. Keep identifiers stable so
// saved widget configurations and shortcuts continue resolving the same timer.
import AppIntents
import Foundation

struct TimerChoice: AppEntity, Hashable {
    let id: String
    let label: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static var defaultQuery = TimerChoiceQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)")
    }
}

struct TimerChoiceQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [TimerChoice.ID]) async throws -> [TimerChoice] {
        let all = TimerStore.loadAll().map { $0.advancedSequence() }
        return identifiers.compactMap { id in
            all.first { $0.id == id }.map { TimerChoice(id: $0.id, label: $0.label) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [TimerChoice] {
        Self.choices(from: TimerStore.loadAll())
    }

    @MainActor
    func entities(matching string: String) async throws -> [TimerChoice] {
        Self.matches(string, in: Self.choices(from: TimerStore.loadAll()))
    }

    static func choices(from payloads: [TimerPayload], at date: Date = Date()) -> [TimerChoice] {
        let current: [TimerPayload] = payloads.map { $0.advancedSequence(at: date) }
        let active: [TimerPayload] = current.filter { payload in
            let remaining = payload.pausedRemaining ?? payload.endDate.timeIntervalSince(date)
            let exhausted = payload.sequence.map { $0.loopIndex >= $0.loopCount } ?? false
            return remaining > 0 && !exhausted
        }
        let sorted: [TimerPayload] = active.sorted { lhs, rhs in
            if lhs.endDate == rhs.endDate { return lhs.id < rhs.id }
            return lhs.endDate < rhs.endDate
        }
        return sorted.map { TimerChoice(id: $0.id, label: $0.label) }
    }

    /// Prefer exact names, but return every duplicate for Siri to disambiguate.
    static func matches(_ string: String, in choices: [TimerChoice]) -> [TimerChoice] {
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return choices }
        let exact = choices.filter { $0.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exact.isEmpty ? choices.filter { $0.label.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil } : exact
    }
}
