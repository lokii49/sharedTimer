//
//  SequenceDescriber.swift
//  sharedTimer
//
//  "Describe it" for New Sequence (1.0.7, D13): turns a sentence like "25 on, 5 off,
//  4 times" or "16:8 fast" into phases, with Apple's on-device model (Foundation
//  Models). Nothing leaves the iPhone. Offered only where Apple Intelligence is
//  available (`isAvailable`); everywhere else the manual editor is the only way.
//
//  The model fills `SequenceDraft`; `phases(from:)` is the deterministic, unit-tested
//  step that clamps it to what the sequence wire format accepts (1 s – 365 d per
//  phase, ≤ 64 phases, ≤ 99 loops, non-empty labels ≤ 512 bytes), so a model mistake
//  can't produce a sequence the app would later reject. Main app only.
//

import Foundation
import FoundationModels

@Generable(description: "A repeating timer sequence: ordered phases, looped a number of times.")
struct SequenceDraft {
    @Guide(description: "The phases in order, e.g. Focus then Break.", .count(1...12))
    var phases: [PhaseDraft]

    @Guide(description: "How many times to run through all the phases.", .range(1...99))
    var loopCount: Int
}

@Generable(description: "One phase of a sequence.")
struct PhaseDraft {
    @Guide(description: "A short name for the phase, two or three words at most, e.g. Focus, Break, Fast, Eating window.")
    var label: String

    @Guide(description: "The phase length in minutes. Hours become minutes: 16 hours is 960.", .range(1...10_080))
    var minutes: Int
}

enum SequenceDescriber {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    enum Failure: Error { case unavailable, nothingUsable }

    /// Asks the on-device model for a draft and clamps it to valid phases.
    static func describe(_ text: String) async throws -> (phases: [SequencePhase], loopCount: Int) {
        guard isAvailable else { throw Failure.unavailable }
        let session = LanguageModelSession(instructions: """
            You turn a short description of a repeating timer into phases and a loop count. \
            Use the person's own words for phase names when they give them, otherwise short \
            common names. "25 on, 5 off" means a 25-minute work phase then a 5-minute break. \
            "16:8" for fasting means a 16-hour fast then an 8-hour eating window, once. \
            If no number of repeats is given, use 1, or 4 for Pomodoro-style work/break pairs.
            """)
        let draft = try await session.respond(to: text, generating: SequenceDraft.self).content
        let result = phases(from: draft)
        guard !result.phases.isEmpty else { throw Failure.nothingUsable }
        return result
    }

    /// Clamps a model draft to what a sequence may hold. Phases keep New Sequence's
    /// defaults (timer kind, alarm on, vibration on).
    static func phases(from draft: SequenceDraft) -> (phases: [SequencePhase], loopCount: Int) {
        let phases = draft.phases.prefix(64).compactMap { phase -> SequencePhase? in
            let label = TimerPayload.clampedLabel(phase.label.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !label.isEmpty else { return nil }
            let seconds = min(max(Double(phase.minutes) * 60, 1), 365 * 86_400)
            return SequencePhase(label: label, duration: seconds)
        }
        return (Array(phases), min(max(draft.loopCount, 1), 99))
    }
}
