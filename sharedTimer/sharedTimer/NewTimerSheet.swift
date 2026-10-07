//
//  NewTimerSheet.swift
//  sharedTimer
//

import SwiftUI
import UIKit

struct NewTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var kind: TimerKind
    @State private var minutes: Double = 5
    @State private var targetDate: Date = Date().addingTimeInterval(86400)
    @State private var alarmEnabled = true
    @State private var vibrationEnabled = true
    @FocusState private var labelFocused: Bool

    let onCreate: (TimerPayload) -> Void

    init(initialKind: TimerKind = .timer, onCreate: @escaping (TimerPayload) -> Void) {
        self._kind = State(initialValue: initialKind)
        self.onCreate = onCreate
    }

    /// Live preview of the sky this timer will get.
    private var previewPayload: TimerPayload {
        TimerPayload.compose(label: label.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : label,
                             kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SkyCard(payload: previewPayload, date: Date())
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
                    kindLocked: true
                )
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle(kind == .timer ? "New Timer" : "New Countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onCreate(TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
