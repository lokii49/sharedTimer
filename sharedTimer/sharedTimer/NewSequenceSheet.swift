//
//  NewSequenceSheet.swift
//  sharedTimer
//

import SwiftUI
import UIKit

/// A starting point the sequence compose sheet seeds itself from — Pomodoro and
/// Intermittent Fasting are just worked examples of the underlying concept (phases
/// that run back-to-back, looping as a whole); "Custom" starts from a single blank
/// phase. Once picked, a template only supplies initial values — the user is free to
/// rename, add, remove, reorder, or edit every phase from there (see CLAUDE.md).
private struct SequenceTemplate: Equatable {
    /// The row label in "Start from" — always a real name, even for Custom.
    let name: String
    /// The name seeded into the "Sequence name" field — distinct from `name` only for
    /// Custom: an empty seed forces the user to actually name it (Start/Save are
    /// disabled on a blank name) instead of quietly saving/starting something titled
    /// "Custom".
    let seedName: String
    let blurb: String
    let phases: [SequencePhase]
    let defaultLoopCount: Int
}

private let sequenceTemplates: [SequenceTemplate] = [
    SequenceTemplate(
        name: "Custom",
        seedName: "",
        blurb: "Start from scratch and add whatever phases you like.",
        phases: [SequencePhase(label: "Phase 1", duration: 5 * 60)],
        defaultLoopCount: 1
    ),
    SequenceTemplate(
        name: "Pomodoro",
        seedName: "Pomodoro",
        blurb: "Work, then rest, on repeat.",
        phases: [
            SequencePhase(label: "Work", kind: .timer, duration: 25 * 60),
            SequencePhase(label: "Rest", kind: .timer, duration: 5 * 60)
        ],
        defaultLoopCount: 4
    ),
    SequenceTemplate(
        name: "Intermittent Fasting",
        seedName: "Intermittent Fasting",
        blurb: "Fast, then eat, day after day.",
        phases: [
            SequencePhase(label: "Fast", kind: .timer, duration: 16 * 3600),
            SequencePhase(label: "Eat", kind: .timer, duration: 8 * 3600)
        ],
        defaultLoopCount: 7
    )
]

/// Stable per-row identity for the phase list, independent of `SequencePhase` itself
/// (which carries no `id` — adding one would mean a Codable back-compat decode and a
/// 4-way cross-target diff for a value that's main-app-only in v1). `ForEach` keyed on
/// array index breaks the moment rows are insertable/deletable/reorderable: deleting a
/// middle phase would make SwiftUI reuse rows positionally, leaving stale text in
/// `TextField`s and jumping focus.
private struct DraftPhase: Identifiable {
    let id = UUID()
    var phase: SequencePhase
}

/// Which starting point currently seeded the draft — a built-in template (by index
/// into the fixed `sequenceTemplates` array) or one of the user's saved sequences (by
/// id). Needed instead of a bare `Int` the moment saved sequences join the list: that
/// list is mutable (deleting a saved sequence shifts every index after it), so an index
/// alone can't safely identify "which one is selected" across an edit.
private enum SequenceSource: Equatable {
    case builtin(index: Int)
    case saved(id: String)
}

/// The seed values a `SequenceSource` currently resolves to — same shape whether it
/// came from a built-in template or a saved sequence, so `isPristine`/`select` don't
/// need to know which.
private struct SequenceSeed: Equatable {
    let name: String
    let phases: [SequencePhase]
    let loopCount: Int
}

/// Compose sheet for a free-form sequence: start from a template or a saved sequence
/// (or from scratch), then add/remove/reorder/edit phases, set the loop count, and
/// optionally save the result for reuse.
struct NewSequenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: SequenceSource = .builtin(index: 0)
    @State private var savedSequences: [SavedSequence] = SavedSequenceStore.loadAll()
    @State private var sequenceName: String
    @State private var draftPhases: [DraftPhase]
    @State private var loopCount: Int
    @State private var startLater = false
    @State private var scheduledStart: Date = Date().addingTimeInterval(3600)

    let onCreate: (TimerPayload) -> Void

    init(onCreate: @escaping (TimerPayload) -> Void) {
        self.onCreate = onCreate
        let first = sequenceTemplates[0]
        self._sequenceName = State(initialValue: first.seedName)
        self._draftPhases = State(initialValue: first.phases.map(DraftPhase.init))
        self._loopCount = State(initialValue: first.defaultLoopCount)
    }

    /// A sequence needs at least one phase (`composeSequence` preconditions on it) and
    /// a name — an editable list lets the user delete down to empty, so Start (and
    /// Save) must be gateable rather than crash.
    private var canCreate: Bool {
        !draftPhases.isEmpty && !sequenceName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func seed(for source: SequenceSource) -> SequenceSeed? {
        switch source {
        case .builtin(let index):
            guard sequenceTemplates.indices.contains(index) else { return nil }
            let template = sequenceTemplates[index]
            return SequenceSeed(name: template.seedName, phases: template.phases, loopCount: template.defaultLoopCount)
        case .saved(let id):
            guard let saved = savedSequences.first(where: { $0.id == id }) else { return nil }
            return SequenceSeed(name: saved.name, phases: saved.phases, loopCount: saved.loopCount)
        }
    }

    /// True as long as nothing has diverged from the given seed's values — used to
    /// decide whether switching "Start from" is still safe to apply. Once the user has
    /// touched the name, phases, or loop count, switching must leave the draft alone
    /// instead of silently discarding their edits.
    private func isPristine(against seed: SequenceSeed) -> Bool {
        sequenceName == seed.name && loopCount == seed.loopCount && draftPhases.map(\.phase) == seed.phases
    }

    private func select(_ newSource: SequenceSource) {
        guard newSource != source else { return }
        let wasPristine = seed(for: source).map(isPristine(against:)) ?? false
        source = newSource
        guard wasPristine, let newSeed = seed(for: newSource) else { return }
        sequenceName = newSeed.name
        draftPhases = newSeed.phases.map(DraftPhase.init)
        loopCount = newSeed.loopCount
    }

    /// Phases with any blank label defaulted, the same way "Add Phase" names a new one
    /// — shared by Start and Save so neither construction path can skip it.
    private func normalizedPhases() -> [SequencePhase] {
        draftPhases.enumerated().map { index, draft in
            var phase = draft.phase
            if phase.label.trimmingCharacters(in: .whitespaces).isEmpty {
                phase.label = "Phase \(index + 1)"
            }
            return phase
        }
    }

    /// Overwrites the saved sequence currently selected, or creates a new one — never
    /// both, so tapping Save repeatedly on the same draft updates one entry instead of
    /// piling up duplicates.
    private func saveSequence() {
        let name = sequenceName.trimmingCharacters(in: .whitespaces)
        let phases = normalizedPhases()
        if case .saved(let id) = source, let index = savedSequences.firstIndex(where: { $0.id == id }) {
            savedSequences[index] = SavedSequence(id: id, name: name, phases: phases, loopCount: loopCount)
        } else {
            let new = SavedSequence(name: name, phases: phases, loopCount: loopCount)
            savedSequences.append(new)
            source = .saved(id: new.id)
        }
        SavedSequenceStore.saveAll(savedSequences)
        // Match what was actually saved (trimmed name, defaulted phase labels) — otherwise
        // `isPristine` compares the un-normalized draft against the normalized seed and
        // reads as diverged even right after a save, silently blocking the next reseed.
        sequenceName = name
        draftPhases = phases.map(DraftPhase.init)
    }

    private func deleteSaved(at offsets: IndexSet) {
        let removedIDs = offsets.map { savedSequences[$0].id }
        savedSequences.remove(atOffsets: offsets)
        SavedSequenceStore.saveAll(savedSequences)
        if case .saved(let id) = source, removedIDs.contains(id) {
            select(.builtin(index: 0))
        }
    }

    @ViewBuilder
    private func startFromRow(name: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        // No .buttonStyle(.plain) here on purpose: the default Form/List button style gives
        // the whole row cell — including the insets above/below the text, which a `Button`
        // label's own .contentShape only covers to its own frame — a tap target, not just
        // the rendered content. .plain drops back to content-only hit-testing.
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(sequenceTemplates.indices, id: \.self) { index in
                        startFromRow(
                            name: sequenceTemplates[index].name,
                            subtitle: sequenceTemplates[index].blurb,
                            isSelected: source == .builtin(index: index)
                        ) {
                            select(.builtin(index: index))
                        }
                    }
                    if !savedSequences.isEmpty {
                        ForEach(savedSequences) { saved in
                            startFromRow(
                                name: saved.name,
                                subtitle: "\(saved.phases.count) phase\(saved.phases.count == 1 ? "" : "s") · \(saved.loopCount)×",
                                isSelected: source == .saved(id: saved.id)
                            ) {
                                select(.saved(id: saved.id))
                            }
                        }
                        .onDelete(perform: deleteSaved)
                    }
                } header: {
                    Text("Start from")
                } footer: {
                    Text("A sequence runs each phase below back-to-back, then loops the whole thing.")
                }

                Section {
                    TextField("Sequence name", text: $sequenceName)
                }

                Section {
                    ForEach($draftPhases) { $draft in
                        NavigationLink {
                            PhaseEditView(phase: $draft.phase)
                        } label: {
                            HStack {
                                Image(systemName: draft.phase.kind == .timer ? "timer" : "calendar")
                                    .foregroundStyle(draft.phase.kind.accentColor)
                                VStack(alignment: .leading) {
                                    Text(draft.phase.label.isEmpty ? "Untitled phase" : draft.phase.label)
                                    Text(TimeFormat.daysHours(draft.phase.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .onDelete { draftPhases.remove(atOffsets: $0) }
                    .onMove { draftPhases.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Phases")
                } footer: {
                    if draftPhases.isEmpty {
                        Text("Add at least one phase to start this sequence.")
                    }
                }

                Section {
                    Button {
                        draftPhases.append(DraftPhase(phase: SequencePhase(label: "Phase \(draftPhases.count + 1)", duration: 5 * 60)))
                    } label: {
                        Label("Add Phase", systemImage: "plus.circle")
                    }
                }

                Section {
                    Stepper("Repeat \(loopCount) time\(loopCount == 1 ? "" : "s")", value: $loopCount, in: 1...99)
                } footer: {
                    Text("Runs \(draftPhases.count) phase\(draftPhases.count == 1 ? "" : "s") per loop, \(loopCount) time\(loopCount == 1 ? "" : "s") total.")
                }

                Section {
                    // Root `.tint(.white)` (ContentView) leaves an untinted Toggle a
                    // plain white switch, inconsistent with every other toggle in the
                    // app (Alarm/Vibrate, PhaseEditView) which all pin to a kind accent.
                    // A sequence mixes phase kinds, so there's no single "the" kind here
                    // — use phase 0's, same accent PhaseEditView already shows for it.
                    Toggle("Start later", isOn: $startLater)
                        .tint(draftPhases.first?.phase.kind.accentColor ?? .orange)
                    if startLater {
                        DatePicker(
                            "Start date",
                            selection: $scheduledStart,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                } footer: {
                    Text(startLater
                         ? "Starts \(scheduledStart.formatted(date: .abbreviated, time: .shortened))."
                         : "Starts right away.")
                }

                Section {
                    Button {
                        saveSequence()
                    } label: {
                        if case .saved = source {
                            Label("Update Saved Sequence", systemImage: "square.and.arrow.down")
                        } else {
                            Label("Save as New Sequence", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(!canCreate)
                } footer: {
                    Text("Save this sequence to select and start it again later without rebuilding it.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle("New Sequence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onCreate(TimerPayload.composeSequence(
                            label: sequenceName.trimmingCharacters(in: .whitespaces),
                            phases: normalizedPhases(),
                            loopCount: loopCount,
                            startDate: startLater ? scheduledStart : nil
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCreate)
                }
            }
        }
    }
}

/// Hours/minutes wheel for a single phase's duration — the same compact-wheel pattern
/// `TimerFieldsView` uses for a plain timer, sized for phases from a few minutes
/// (Pomodoro) to many hours (Intermittent Fasting). Floors at 1 minute: a zero-duration
/// phase would make `advancedSequence` blow straight through it on every tick.
private struct PhaseDurationPicker: View {
    @Binding var duration: TimeInterval

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { Int(duration) / 3600 },
            set: { newHours in
                let minutes = (Int(duration) % 3600) / 60
                duration = max(60, TimeInterval(newHours * 3600 + minutes * 60))
            }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { (Int(duration) % 3600) / 60 },
            set: { newMinutes in
                let hours = Int(duration) / 3600
                duration = max(60, TimeInterval(hours * 3600 + newMinutes * 60))
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hoursBinding) {
                ForEach(0..<24) { h in Text("\(h) hr").tag(h) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)

            Picker("Minutes", selection: minutesBinding) {
                ForEach(0..<60) { m in Text("\(m) min").tag(m) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 120)
    }
}

/// Drill-in editor for one phase of a sequence: label, duration, cosmetic look
/// (`SequencePhase.kind` is icon/tint only — never date-anchored, since a phase
/// re-runs on every loop, see `TimerModel.swift`), and its own alarm/vibrate toggles.
private struct PhaseEditView: View {
    @Binding var phase: SequencePhase

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $phase.label)

                Picker("Look", selection: $phase.kind) {
                    Text("Timer").tag(TimerKind.timer)
                    Text("Countdown").tag(TimerKind.countdown)
                }
                .pickerStyle(.segmented)
            }

            Section {
                PhaseDurationPicker(duration: $phase.duration)
            } footer: {
                Text("How long this phase runs each time it comes up.")
            }

            Section {
                Toggle("Alarm", isOn: $phase.alarmEnabled)
                    .tint(phase.kind.accentColor)
                Toggle("Vibrate", isOn: $phase.vibrationEnabled)
                    .tint(phase.kind.accentColor)
            } header: {
                Text("When this phase ends")
            } footer: {
                Text(phase.alarmEnabled || phase.vibrationEnabled
                     ? "Rings or buzzes full-screen with Stop and Repeat, even when the app is closed or the phone is on silent."
                     : "A quiet notification instead — no ringing.")
            }
        }
        .navigationTitle(phase.label.isEmpty ? "Phase" : phase.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
