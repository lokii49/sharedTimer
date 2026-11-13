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
    /// The longest phase New Sequence's hours/minutes wheel can show.
    static let maximumPhaseSeconds: TimeInterval = 23 * 3600 + 59 * 60
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
            // New Sequence's phase wheel stops at 23 h 59 min; a longer phase showed the
            // wrong wheel value (no matching tag) next to a row reading "1d 12h".
            let seconds = min(max(Double(phase.minutes) * 60, 1), maximumPhaseSeconds)
            return SequencePhase(label: label, duration: seconds)
        }
        return (Array(phases), min(max(draft.loopCount, 1), 99))
    }
}

import SwiftUI

/// D13 · B: "Describe…" in New Sequence's Start from list opens this sheet. The
/// generated phases are previewed and only replace the draft on "Use These Phases",
/// so a misread never overwrites anything.
struct DescribeSequenceSheet: View {
    let onUse: (_ phases: [SequencePhase], _ loopCount: Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: (phases: [SequencePhase], loopCount: Int)?
    @State private var working = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("25 on, 5 off, 4 times", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(create)
                    Button {
                        create()
                    } label: {
                        HStack {
                            Label("Create Phases", systemImage: "sparkles")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("Apple Intelligence builds the phases on this iPhone. Nothing is sent anywhere.")
                }

                if failed {
                    Section {
                        Text("Couldn’t find phases in that. Try something like “16:8 fast” or “50 work, 10 break, 3 times”.")
                            .font(.footnote)
                    }
                }

                if let result {
                    Section {
                        ForEach(Array(result.phases.enumerated()), id: \.offset) { _, phase in
                            HStack {
                                Text(phase.label)
                                Spacer()
                                Text(RecentTimer.lengthText(phase.duration)).foregroundStyle(.secondary)
                            }
                        }
                        Button("Use These Phases") {
                            onUse(result.phases, result.loopCount)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    } header: {
                        Text("Preview")
                    } footer: {
                        Text("Loops: \(result.loopCount)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle("Describe a Sequence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func create() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !working else { return }
        working = true
        failed = false
        Task {
            do {
                result = try await SequenceDescriber.describe(prompt)
            } catch {
                result = nil
                failed = true
            }
            working = false
        }
    }
}
