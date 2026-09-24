//
//  TimerModel.swift
//  sharedTimerClip
//

import Foundation
import SwiftUI

enum TimerShareMode: String, Codable {
    case appCard
    case link
}

enum TimerKind: String, Codable {
    case timer
    case countdown
}

/// One phase of a sequence timer (e.g. Pomodoro's "Work" or "Rest"). `kind` here is
/// cosmetic only — icon/tint for the phase — never date-anchored the way a top-level
/// `TimerPayload.kind == .countdown` is, since a phase re-runs on every loop.
struct SequencePhase: Codable, Hashable {
    var label: String
    var kind: TimerKind
    var duration: TimeInterval
    var alarmEnabled: Bool
    var vibrationEnabled: Bool

    init(label: String, kind: TimerKind = .timer, duration: TimeInterval, alarmEnabled: Bool = true, vibrationEnabled: Bool = true) {
        self.label = label
        self.kind = kind
        self.duration = max(1, duration)
        self.alarmEnabled = alarmEnabled
        self.vibrationEnabled = vibrationEnabled
    }
}

/// Carried on a sequence-owning `TimerPayload`. `phaseIndex`/`loopIndex` name whichever
/// phase is currently materialized into the payload's top-level fields — see
/// `TimerPayload.advancedSequence(at:)`, the only place these ever change.
struct SequenceInfo: Codable, Hashable {
    var phases: [SequencePhase]
    var loopCount: Int
    var phaseIndex: Int
    var loopIndex: Int
}

struct TimerPayload: Codable, Identifiable {
    let id: String
    /// `var`, not `let`: for a sequence-owning payload (`sequence != nil`), this and
    /// `duration`/`kind`/`alarmEnabled`/`vibrationEnabled` below are the "currently
    /// materialized phase" projection — `advancedSequence(at:)` overwrites them in
    /// place at each phase transition so every existing consumer (AlarmController,
    /// NotificationScheduler, LiveActivityController, widgets, SkyCard) keeps reading
    /// "whichever phase is running now" with no sequence-awareness of its own.
    var label: String
    var endDate: Date
    var duration: TimeInterval
    var pausedRemaining: TimeInterval?
    var kind: TimerKind
    /// When false, finishing raises only a quiet notification (standard sound, no
    /// AlarmKit full-screen ring, no in-app alarm loop) — the compose-sheet "Alarm"
    /// toggle. Defaults true so every pre-toggle timer/link keeps its old behavior.
    var alarmEnabled: Bool
    /// When true, finishing also repeats the device vibration in the foreground
    /// until stopped — the compose-sheet "Vibrate" toggle. Independent of
    /// `alarmEnabled`: it can vibrate with the alarm off, or stay silent with the
    /// alarm on. Defaults true so every pre-toggle timer/link keeps buzzing.
    var vibrationEnabled: Bool
    /// Non-nil only for a Pomodoro/Intermittent-Fasting style sequence. Absent from
    /// share links/CloudKit/watch by design (main-app-only in v1) — see CLAUDE.md.
    var sequence: SequenceInfo?
    /// Non-nil only for a sequence-owning payload created with "Start later" — the
    /// picked start date/time for phase 0. Sequence-only, same as `sequence` itself
    /// (absent from share links/CloudKit/watch by design) — `endDate` is computed at
    /// creation time from this same as any other far-future endDate, so scheduling
    /// (AlarmKit/NotificationScheduler) needs no changes at all: this field is purely
    /// derived display state, never mutated after creation. `isPending(at:)` is the only
    /// thing that reads it. See CLAUDE.md.
    var scheduledStartDate: Date?

    init(id: String = UUID().uuidString, label: String, duration: TimeInterval, kind: TimerKind = .timer, alarmEnabled: Bool = true, vibrationEnabled: Bool = true, sequence: SequenceInfo? = nil, scheduledStartDate: Date? = nil) {
        self.id = id
        self.label = label
        self.duration = duration
        self.endDate = Date().addingTimeInterval(duration)
        self.pausedRemaining = nil
        self.kind = kind
        self.alarmEnabled = alarmEnabled
        self.vibrationEnabled = vibrationEnabled
        self.sequence = sequence
        self.scheduledStartDate = scheduledStartDate
    }

    init(id: String, label: String, endDate: Date, duration: TimeInterval, pausedRemaining: TimeInterval? = nil, kind: TimerKind = .timer, alarmEnabled: Bool = true, vibrationEnabled: Bool = true, sequence: SequenceInfo? = nil, scheduledStartDate: Date? = nil) {
        self.id = id
        self.label = label
        self.endDate = endDate
        self.duration = duration
        self.pausedRemaining = pausedRemaining
        self.kind = kind
        self.alarmEnabled = alarmEnabled
        self.vibrationEnabled = vibrationEnabled
        self.sequence = sequence
        self.scheduledStartDate = scheduledStartDate
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, endDate, duration, pausedRemaining, kind, alarmEnabled, vibrationEnabled, sequence, scheduledStartDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        endDate = try container.decode(Date.self, forKey: .endDate)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        pausedRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        // Older shared links/stored timers predate `kind`; treat them as plain timers.
        kind = try container.decodeIfPresent(TimerKind.self, forKey: .kind) ?? .timer
        // Predates the alarm toggle -> keep the old always-alarm behavior.
        alarmEnabled = try container.decodeIfPresent(Bool.self, forKey: .alarmEnabled) ?? true
        // Predates the vibration toggle -> false, NOT true. Unlike `alarmEnabled`
        // (whose "loud" meaning never changed), `vibrationEnabled` started as a
        // harmless foreground-only buzz and only later started also routing through
        // AlarmKit for a full-screen alert — decoding old data as "on" would silently
        // upgrade an already-quiet stored timer or shared link into a full-screen
        // takeover its creator never asked for.
        vibrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .vibrationEnabled) ?? false
        // Brand new field, no prior default to preserve — absent simply means "not a sequence."
        sequence = try container.decodeIfPresent(SequenceInfo.self, forKey: .sequence)
        // Brand new field, no prior default to preserve — absent simply means "not pending."
        scheduledStartDate = try container.decodeIfPresent(Date.self, forKey: .scheduledStartDate)
    }

    var isPaused: Bool {
        pausedRemaining != nil
    }

    /// True until the picked "Start later" moment arrives — pure/date-parameterized so
    /// it stays testable and consistent with the rest of this file. Never true for a
    /// payload created without a scheduled start, and never true again once the start
    /// date has passed (this field is never cleared afterward — see its declaration).
    func isPending(at date: Date = Date()) -> Bool {
        guard let scheduledStartDate else { return false }
        return scheduledStartDate > date
    }

    var remaining: TimeInterval {
        if let pausedRemaining {
            return max(0, pausedRemaining)
        }
        return max(0, endDate.timeIntervalSinceNow)
    }

    var isExpired: Bool {
        !isPaused && remaining <= 0
    }

    /// True once remaining time has reached zero, whether or not the timer is
    /// currently paused. `isExpired` deliberately stays false while paused — that's
    /// what stops the alarm/notification firing for a timer someone paused on
    /// purpose — but a paused timer at zero should still read as finished in list
    /// grouping and other display contexts, not sit indefinitely as "active/paused".
    var isFinished: Bool {
        remaining <= 0
    }

    /// Fraction of the timer remaining, for progress rings. 1 = just started, 0 = done.
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let currentRemaining = isPaused ? (pausedRemaining ?? 0) : endDate.timeIntervalSince(date)
        return min(1, max(0, currentRemaining / duration))
    }

    func paused(at date: Date = Date()) -> TimerPayload {
        guard !isPaused else { return self }
        var copy = self
        copy.pausedRemaining = max(0, endDate.timeIntervalSince(date))
        return copy
    }

    func resumed(at date: Date = Date()) -> TimerPayload {
        guard let pausedRemaining else { return self }
        var copy = self
        copy.endDate = date.addingTimeInterval(pausedRemaining)
        copy.pausedRemaining = nil
        return copy
    }

    func extended(by interval: TimeInterval) -> TimerPayload {
        var copy = self
        if let pausedRemaining = copy.pausedRemaining {
            copy.pausedRemaining = max(0, pausedRemaining + interval)
        } else {
            copy.endDate = copy.endDate.addingTimeInterval(interval)
        }
        return copy
    }

    /// Restart a finished timer/countdown in place — same id, label and original
    /// `duration`, running again from now. Keeps the CloudLink and any shared link valid.
    /// For a sequence-owning payload, restarts the whole sequence at phase 0/loop 0
    /// (never "repeat the phase that happened to be current") — see CLAUDE.md.
    func repeated(at date: Date = Date()) -> TimerPayload {
        var copy = self
        if var seq = copy.sequence, let first = seq.phases.first {
            seq.phaseIndex = 0
            seq.loopIndex = 0
            copy.label = first.label
            copy.kind = first.kind
            copy.duration = first.duration
            copy.alarmEnabled = first.alarmEnabled
            copy.vibrationEnabled = first.vibrationEnabled
            copy.endDate = date.addingTimeInterval(first.duration)
            copy.sequence = seq
        } else {
            copy.endDate = date.addingTimeInterval(duration)
        }
        copy.pausedRemaining = nil
        // A repeated payload is running now, by definition -- clear any stale scheduled
        // start so it never reads as pending (belt-and-suspenders: nothing currently
        // calls repeated() on a still-pending payload, but isPending() must never lie
        // about a payload this function just started).
        copy.scheduledStartDate = nil
        return copy
    }

    /// Advances a sequence-owning payload to whatever phase should be current *right
    /// now*, re-derived from scratch each call — never a single "+1 phase" step. This
    /// is what makes correctness independent of how long the app was backgrounded:
    /// reopening after missing several whole phases still lands on the right one.
    /// No-op for a plain (non-sequence) payload, a paused one, or one not yet expired.
    func advancedSequence(at date: Date = Date()) -> TimerPayload {
        guard var seq = sequence, !seq.phases.isEmpty else { return self }
        var copy = self
        // Bounded by index (phases.count * loopCount), not by the clock, so a
        // malformed zero/negative-duration phase can never spin this forever.
        for _ in 0..<(seq.phases.count * max(1, seq.loopCount)) {
            // Date-parameterized remaining check, not `copy.remaining` (which always reads
            // the real wall clock) — keeps this function pure/testable against `date`.
            guard !copy.isPaused, copy.endDate.timeIntervalSince(date) <= 0, seq.loopIndex < seq.loopCount else { break }
            seq.phaseIndex += 1
            if seq.phaseIndex >= seq.phases.count {
                seq.phaseIndex = 0
                seq.loopIndex += 1
            }
            guard seq.loopIndex < seq.loopCount else {
                // Sequence exhausted — settle permanently on the last-run phase, isExpired forever after.
                seq.loopIndex = seq.loopCount
                copy.sequence = seq
                break
            }
            let next = seq.phases[seq.phaseIndex]
            // Chain off the previous boundary, not `date` — exact regardless of how
            // late this happens to run, and correctly compounds through pause/resume/extend.
            copy.endDate = copy.endDate.addingTimeInterval(next.duration)
            copy.duration = next.duration
            copy.label = next.label
            copy.kind = next.kind
            copy.alarmEnabled = next.alarmEnabled
            copy.vibrationEnabled = next.vibrationEnabled
            copy.sequence = seq
        }
        return copy
    }

    /// A literal one-phase-forward step for an explicit "Next" action (the AlarmKit
    /// alert's secondary button) — deliberately NOT `advancedSequence(at:)`. That
    /// function chains the new phase's `endDate` off the stale *original* boundary, so
    /// it's correct for "re-derive whatever should be current after being away," but
    /// wrong for "the user just tapped Next, start the next phase now": with short
    /// phase durations, any real delay between the alert firing and the tap makes
    /// `advancedSequence` walk through (or exhaust) several phases in one call —
    /// confirmed on device as "Next" looking like it silently ended the sequence.
    /// This instead always lands on exactly the next phase, timed from `date` (the
    /// moment of the tap), regardless of how long the alert sat there first.
    func steppedToNextPhase(at date: Date = Date()) -> TimerPayload {
        guard var seq = sequence, !seq.phases.isEmpty else { return self }
        var copy = self
        seq.phaseIndex += 1
        if seq.phaseIndex >= seq.phases.count {
            seq.phaseIndex = 0
            seq.loopIndex += 1
        }
        guard seq.loopIndex < seq.loopCount else {
            seq.loopIndex = seq.loopCount
            copy.sequence = seq
            return copy
        }
        let next = seq.phases[seq.phaseIndex]
        copy.endDate = date.addingTimeInterval(next.duration)
        copy.duration = next.duration
        copy.label = next.label
        copy.kind = next.kind
        copy.alarmEnabled = next.alarmEnabled
        copy.vibrationEnabled = next.vibrationEnabled
        copy.sequence = seq
        return copy
    }

    /// "Phase 2 of 4 · Loop 1 of 3" — nil for a plain payload, and once the sequence is
    /// fully exhausted (the plain "Finished ..." subtitle already covers that case).
    var sequenceCaption: String? {
        guard let sequence, sequence.loopIndex < sequence.loopCount else { return nil }
        return "Phase \(sequence.phaseIndex + 1) of \(sequence.phases.count) · Loop \(sequence.loopIndex + 1) of \(sequence.loopCount)"
    }

    /// Builds a sequence-owning payload (Pomodoro/Intermittent-Fasting style) from a
    /// preset's phase list + loop count. Main-app-only in v1 — never round-tripped
    /// through `url()`/`from(url:)` or CloudKit, so no back-compat concerns here.
    /// `startDate` in the past (or omitted) means "start now" -- same clamp as `compose`.
    static func composeSequence(label: String, phases: [SequencePhase], loopCount: Int, startDate: Date? = nil) -> TimerPayload {
        precondition(!phases.isEmpty, "a sequence needs at least one phase")
        let first = phases[0]
        let effectiveStart = startDate.flatMap { $0 > Date() ? $0 : nil }
        let seq = SequenceInfo(phases: phases, loopCount: max(1, loopCount), phaseIndex: 0, loopIndex: 0)
        return TimerPayload(
            id: UUID().uuidString, label: label,
            endDate: (effectiveStart ?? Date()).addingTimeInterval(first.duration),
            duration: first.duration, kind: first.kind,
            alarmEnabled: first.alarmEnabled, vibrationEnabled: first.vibrationEnabled,
            sequence: seq, scheduledStartDate: effectiveStart
        )
    }

    /// Builds a payload from compose-sheet inputs shared by every creation surface
    /// (Messages, main app). "Start later" is sequence-only (see `composeSequence`) --
    /// a plain timer/countdown always starts now.
    static func compose(label: String, kind: TimerKind, minutes: Double, targetDate: Date, alarmEnabled: Bool = true, vibrationEnabled: Bool = true) -> TimerPayload {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = trimmed.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : trimmed
        switch kind {
        case .timer:
            return TimerPayload(label: finalLabel, duration: max(1, minutes * 60), kind: .timer, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
        case .countdown:
            return TimerPayload(label: finalLabel, duration: max(1, targetDate.timeIntervalSinceNow), kind: .countdown, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
        }
    }

    func url() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        var items = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(endDate.timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: String(duration)),
            URLQueryItem(name: "kind", value: kind.rawValue)
        ]
        if let pausedRemaining {
            items.append(URLQueryItem(name: "paused", value: String(pausedRemaining)))
        }
        // Only emitted when off — absence means "alarm on", so old links stay valid.
        if !alarmEnabled {
            items.append(URLQueryItem(name: "alarm", value: "0"))
        }
        // Unlike `alarm`, always emitted explicitly (not just when off): absence has
        // to unambiguously mean "predates the vibration toggle" so an old link decodes
        // as off (see `from(url:)`) — `alarm`'s on-by-default-when-absent convention is
        // safe because "alarm on" never changed meaning, but "vibration on" started
        // also triggering a full-screen AlarmKit takeover, so a pre-existing link
        // silently inheriting "on" would surprise whoever shared it.
        items.append(URLQueryItem(name: "vib", value: vibrationEnabled ? "1" : "0"))
        components.queryItems = items
        return components.url!
    }

    static func from(url: URL?) -> TimerPayload? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              let label = items.first(where: { $0.name == "label" })?.value,
              let endString = items.first(where: { $0.name == "end" })?.value,
              let endInterval = Double(endString) else {
            return nil
        }
        let endDate = Date(timeIntervalSince1970: endInterval)
        let durString = items.first(where: { $0.name == "dur" })?.value
        let duration = durString.flatMap(Double.init) ?? max(endDate.timeIntervalSinceNow, 1)
        let pausedRemaining = items.first(where: { $0.name == "paused" })?.value.flatMap(Double.init)
        let kind = items.first(where: { $0.name == "kind" })?.value.flatMap(TimerKind.init(rawValue:)) ?? .timer
        // Absent -> alarm on (old links). Only "0" turns it off.
        let alarmEnabled = items.first(where: { $0.name == "alarm" })?.value != "0"
        // Absent -> vibration off (a link from before the toggle existed): unlike
        // `alarm`, "vibration on" now also means a full-screen AlarmKit takeover, so an
        // old link can't default to it. "1" turns it on; anything else (including "0"
        // or absent) is off.
        let vibrationEnabled = items.first(where: { $0.name == "vib" })?.value == "1"
        // "Start later" is sequence-only and sequences are never shared -- a shared
        // link's payload is never pending, same as it's never sequence-owning.
        return TimerPayload(id: id, label: label, endDate: endDate, duration: duration, pausedRemaining: pausedRemaining, kind: kind, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }
}

/// Day-aware time formatting shared by every surface that renders a countdown.
enum TimeFormat {
    /// Countdowns at or beyond this range switch from a duration string to a calendar breakdown.
    static let calendarThreshold: TimeInterval = 7 * 86400

    /// "3d 04:12:09" beyond a day, "4:12:09" beyond an hour, else "12:09".
    static func remaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, h, m, s)
        }
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// "3d 4h" — a coarse duration for surfaces that refresh on a timeline rather than every
    /// second; never claims a minutes/seconds precision it can't actually keep live.
    static func daysHours(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let h = (total % 86400) / 3600
        return h > 0 ? "\(days)d \(h)h" : "\(days)d"
    }

    /// "1y 2mo", "2mo 15d", "21d" — calendar-aware breakdown for far-out countdowns.
    static func calendarBreakdown(_ interval: TimeInterval, at now: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: now, to: now.addingTimeInterval(max(0, interval)))
        let y = comps.year ?? 0, m = comps.month ?? 0, d = max(comps.day ?? 0, 0)
        if y > 0 { return m > 0 ? "\(y)y \(m)mo" : "\(y)y" }
        if m > 0 { return d > 0 ? "\(m)mo \(d)d" : "\(m)mo" }
        return "\(d)d"
    }

    /// Single most significant unit, for ultra-compact slots like the Dynamic Island's compact views.
    static func compactCalendar(_ interval: TimeInterval, at now: Date = Date()) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: now, to: now.addingTimeInterval(max(0, interval)))
        if let y = comps.year, y > 0 { return "\(y)y" }
        if let m = comps.month, m > 0 { return "\(m)mo" }
        return "\(max(comps.day ?? 0, 0))d"
    }

    /// Chooser for surfaces that tick live every second (`TimelineView`, in-app): full precision
    /// under `calendarThreshold`, calendar breakdown beyond it.
    static func display(_ interval: TimeInterval, at now: Date = Date()) -> String {
        interval >= calendarThreshold ? calendarBreakdown(interval, at: now) : remaining(interval)
    }

    /// Chooser for surfaces that only refresh on a timeline or content update (widgets, Live
    /// Activities): never renders a seconds field it can't actually keep live.
    static func snapshot(_ interval: TimeInterval, at now: Date = Date()) -> String {
        interval >= calendarThreshold ? calendarBreakdown(interval, at: now) : daysHours(interval)
    }

    /// Ultra-compact counterpart to `snapshot`, for the Dynamic Island's compact slots.
    static func compactSnapshot(_ interval: TimeInterval, at now: Date = Date()) -> String {
        interval >= calendarThreshold ? compactCalendar(interval, at: now) : "\(max(0, Int(interval)) / 86400)d"
    }

    /// Fixed-width zero-padded digits for a widget where the numbers are the whole point:
    /// "HH:MM:SS" under the calendar threshold, "YY:MM:DD" beyond it. Always exactly 8
    /// characters, so a big font sized for it doesn't jitter as the value changes.
    static func bigDigits(_ interval: TimeInterval, at now: Date = Date()) -> String {
        if interval >= calendarThreshold {
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: now, to: now.addingTimeInterval(max(0, interval)))
            return String(format: "%02d:%02d:%02d", max(0, comps.year ?? 0), max(0, comps.month ?? 0), max(0, comps.day ?? 0))
        }
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "2026-08-11" target date, e.g. for countdown rows and share text.
    static func targetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension TimerKind {
    /// System accents, one per kind: orange for timers (the Clock app's color) and red
    /// for date countdowns (the Calendar app's color). System colors adapt to Light/Dark
    /// Mode and accessibility settings on their own.
    var accentColor: Color {
        switch self {
        case .timer: return .orange
        case .countdown: return .red
        }
    }

    var symbolName: String {
        self == .countdown ? "calendar" : "timer"
    }
}

/// Paused state accent — system yellow, distinct from both kind accents.
let pausedColor = Color.yellow
