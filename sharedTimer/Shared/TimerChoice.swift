// Shared by Siri/Shortcuts and the single-timer widget. Keep identifiers stable so
// saved widget configurations and shortcuts continue resolving the same timer.
//
// N9 (1.0.10): an `IndexedEntity` (Spotlight items in TimerSpotlightIndex are associated
// with it) whose query is also an `EnumerableEntityQuery`, so Shortcuts generates a
// "Find Timers" action that filters on the properties below. Equality stays id + name,
// as before (ContentView refreshes Siri's parameters when that changes).
import AppIntents
import CoreSpotlight
import Foundation

struct TimerChoice: IndexedEntity, Hashable {
    let id: String
    @Property(title: "Name", indexingKey: \.title) var label: String
    @Property(title: "Kind") var kind: TimerChoiceKind
    @Property(title: "State") var state: TimerChoiceState
    /// The current phase's or run's end (a paused timer's is when it was paused + left).
    @Property(title: "Ends") var endDate: Date

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Timer"
    static var defaultQuery = TimerChoiceQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)")
    }

    init(id: String, label: String, kind: TimerChoiceKind = .timer, state: TimerChoiceState = .running, endDate: Date = .distantFuture) {
        self.id = id
        self.label = label
        self.kind = kind
        self.state = state
        self.endDate = endDate
    }

    /// From a stored payload, projected to `date` (its current phase/occurrence).
    init(payload stored: TimerPayload, at date: Date = Date()) {
        let payload = stored.advancedSequence(at: date)
        self.init(id: payload.id, label: payload.label,
                  kind: payload.sequence != nil ? .sequence : payload.kind == .countdown ? .countdown : .timer,
                  state: TimerChoiceState(payload, at: date),
                  endDate: payload.pausedRemaining.map { date.addingTimeInterval($0) } ?? payload.endDate)
    }

    static func == (lhs: TimerChoice, rhs: TimerChoice) -> Bool { lhs.id == rhs.id && lhs.label == rhs.label }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(label) }
}

enum TimerChoiceKind: String, AppEnum {
    case timer, countdown, sequence
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Kind"
    static var caseDisplayRepresentations: [TimerChoiceKind: DisplayRepresentation] = [
        .timer: "Timer", .countdown: "Countdown", .sequence: "Sequence"
    ]
}

enum TimerChoiceState: String, AppEnum {
    case running, paused, scheduled, finished
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "State"
    static var caseDisplayRepresentations: [TimerChoiceState: DisplayRepresentation] = [
        .running: "Running", .paused: "Paused", .scheduled: "Scheduled", .finished: "Finished"
    ]

    /// `payload` already projected to `date`.
    init(_ payload: TimerPayload, at date: Date) {
        let exhausted = payload.sequence.map { $0.loopIndex >= $0.loopCount } ?? false
        let remaining = payload.pausedRemaining ?? payload.endDate.timeIntervalSince(date)
        if exhausted || remaining <= 0 { self = .finished }
        else if payload.isPending(at: date) { self = .scheduled }
        else if payload.isPaused { self = .paused }
        else { self = .running }
    }
}

struct TimerChoiceQuery: EntityStringQuery, EnumerableEntityQuery {
    /// Every stored timer, finished ones too, for the generated Find action to filter.
    @MainActor
    func allEntities() async throws -> [TimerChoice] {
        Self.all(from: TimerStore.loadAll())
    }

    static func all(from payloads: [TimerPayload], at date: Date = Date()) -> [TimerChoice] {
        payloads.map { TimerChoice(payload: $0, at: date) }
            .sorted { $0.endDate == $1.endDate ? $0.id < $1.id : $0.endDate < $1.endDate }
    }

    @MainActor
    func entities(for identifiers: [TimerChoice.ID]) async throws -> [TimerChoice] {
        let all = TimerStore.loadAll().map { $0.advancedSequence() }
        return identifiers.compactMap { id in
            all.first { $0.id == id }.map { TimerChoice(payload: $0) }
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
        return sorted.map { TimerChoice(payload: $0, at: date) }
    }

    /// Prefer exact names, but return every duplicate for Siri to disambiguate.
    static func matches(_ string: String, in choices: [TimerChoice]) -> [TimerChoice] {
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return choices }
        let exact = choices.filter { $0.label.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exact.isEmpty ? choices.filter { $0.label.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil } : exact
    }
}
