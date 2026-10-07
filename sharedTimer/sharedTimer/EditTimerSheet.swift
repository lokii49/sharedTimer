//
//  EditTimerSheet.swift
//  sharedTimer
//

import SwiftUI

/// Rename a timer/countdown, flip its Alarm/Vibrate toggles, or move a countdown's
/// target date — in place, keeping its id, CloudLink and share links. A timer's time
/// changes through +1:00/Extend, so its length wheel isn't offered here. Sequences are
/// never edited (see `TimerPayload.edited`); callers hide the entry point for them.
struct EditTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: TimerPayload
    let onSave: (TimerPayload) -> Void

    @State private var label: String
    @State private var kind: TimerKind
    @State private var minutes: Double
    @State private var targetDate: Date
    @State private var alarmEnabled: Bool
    @State private var vibrationEnabled: Bool
    @FocusState private var labelFocused: Bool

    init(payload: TimerPayload, onSave: @escaping (TimerPayload) -> Void) {
        self.original = payload
        self.onSave = onSave
        _label = State(initialValue: payload.label)
        _kind = State(initialValue: payload.kind)
        _minutes = State(initialValue: payload.duration / 60)
        _targetDate = State(initialValue: payload.endDate)
        _alarmEnabled = State(initialValue: payload.alarmEnabled)
        _vibrationEnabled = State(initialValue: payload.vibrationEnabled)
    }

    private var edited: TimerPayload {
        original.edited(label: label, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled,
                        targetDate: kind == .countdown ? targetDate : nil)
    }

    /// `edited` always restamps `updatedAt`, so compare the fields an edit can change.
    private var hasChanges: Bool {
        let next = edited
        return next.label != original.label
            || next.alarmEnabled != original.alarmEnabled
            || next.vibrationEnabled != original.vibrationEnabled
            || next.endDate != original.endDate
    }

    private var timeZone: TimeZone {
        original.recurrence.flatMap { TimeZone(identifier: $0.timeZoneID) } ?? .current
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SkyCard(payload: edited, date: Date())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    alarmEnabled: $alarmEnabled,
                    vibrationEnabled: $vibrationEnabled,
                    labelFocused: $labelFocused,
                    kindLocked: true,
                    yearlyCountdown: original.recurrence != nil,
                    showsTimerLength: false,
                    targetDateDisabled: original.isPaused
                )
                .environment(\.timeZone, timeZone)
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle(kind == .timer ? "Edit Timer" : "Edit Countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(edited)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasChanges)
                }
            }
        }
    }
}
