//
//  TimerFieldsView.swift
//  sharedTimerMessages
//

import SwiftUI

/// Shared compose fields for creating a timer or a date-targeted countdown, as `Form`
/// sections. Embedded by both the Messages compose sheet and the main app's "New" sheet;
/// each host supplies its own trailing action (Start & Share vs. Start).
struct TimerFieldsView: View {
    @Binding var label: String
    @Binding var kind: TimerKind
    @Binding var minutes: Double
    @Binding var targetDate: Date
    @Binding var alarmEnabled: Bool
    @Binding var vibrationEnabled: Bool
    var labelFocused: FocusState<Bool>.Binding
    /// True when the host already asked "timer or countdown?" before this view ever
    /// appeared (the main app's "+" menu, or a Home Screen Quick Action) — showing the
    /// Type picker again would just re-ask a question the user already answered, so it
    /// is hidden instead (the navigation title already names the kind). Defaults false
    /// for the Messages compose sheet, which never pre-picks a kind.
    var kindLocked: Bool = false

    private let presets: [Double] = [1, 3, 5, 10, 15, 30, 60]
    private let datePresets: [(String, TimeInterval)] = [
        ("Tomorrow", 86400),
        ("In a week", 7 * 86400),
        ("In a month", 30 * 86400)
    ]

    var body: some View {
        Section {
            TextField("Label", text: $label)
                .focused(labelFocused)

            if !kindLocked {
                Picker("Type", selection: $kind) {
                    Text("Timer").tag(TimerKind.timer)
                    Text("Countdown").tag(TimerKind.countdown)
                }
                .pickerStyle(.segmented)
            }
        }

        Section {
            Toggle("Alarm", isOn: $alarmEnabled)
                // Root .tint(.white) would make the "on" track white-on-white; pin it
                // to the kind accent so it reads (orange for a timer, red for a countdown).
                .tint(kind.accentColor)
            // Independent of the alarm toggle on purpose — vibration can stay on with
            // the alarm off (a silent buzz instead of a ring) or off with the alarm on.
            Toggle("Vibrate", isOn: $vibrationEnabled)
                .tint(kind.accentColor)
        } header: {
            Text("When it ends")
        } footer: {
            Text(alarmFootnote)
        }

        if kind == .timer {
            Section {
                HStack(spacing: 0) {
                    wheelColumn(hoursBinding, range: 0...23, unit: "hours")
                    wheelColumn(minutesBinding, range: 0...59, unit: "min")
                    wheelColumn(secondsBinding, range: 0...59, unit: "sec")
                }
                .frame(height: 160)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { m in
                            Button("\(Int(m)) min") {
                                minutes = m
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Int(minutes) == Int(m) ? kind.accentColor : nil)
                        }
                    }
                }
            } footer: {
                Text("Ends at \(Date().addingTimeInterval(minutes * 60).formatted(date: .omitted, time: .shortened))")
            }
        } else {
            Section {
                DatePicker(
                    "Target date",
                    selection: $targetDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )

                HStack(spacing: 8) {
                    ForEach(datePresets, id: \.0) { title, offset in
                        Button(title) {
                            targetDate = Date().addingTimeInterval(offset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            } footer: {
                Text("Counting down to \(TimeFormat.targetDate(targetDate))")
            }
        }
    }

    /// Either toggle alone reaches AlarmKit's full-screen Stop/Repeat panel now — a
    /// countdown ringing when a far-out date finally arrives is exactly the point. The
    /// alarm toggle picks the loud tone; vibration-only (alarm off) plays no audible
    /// sound (a silent asset), same full-screen/lock-screen presence either way.
    private var alarmFootnote: String {
        if alarmEnabled {
            return "Rings full-screen with Stop and Repeat, even when the app is closed or the phone is on silent."
        }
        if vibrationEnabled {
            return "Buzzes full-screen with Stop and Repeat, no sound, even when the app is closed or the phone is on silent."
        }
        return "A quiet notification instead — no ringing."
    }

    // MARK: - Timer wheel (hours / minutes / seconds, derived from `minutes`)

    private var totalSeconds: Int {
        Int((minutes * 60).rounded())
    }

    private func setTotalSeconds(_ seconds: Int) {
        minutes = Double(max(0, seconds)) / 60.0
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { totalSeconds / 3600 },
            set: { setTotalSeconds($0 * 3600 + totalSeconds % 3600) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { (totalSeconds % 3600) / 60 },
            set: { setTotalSeconds((totalSeconds / 3600) * 3600 + $0 * 60 + totalSeconds % 60) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { totalSeconds % 60 },
            set: { setTotalSeconds((totalSeconds / 60) * 60 + $0) }
        )
    }

    private func wheelColumn(_ value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: value) {
                ForEach(range, id: \.self) { v in
                    Text("\(v)").tag(v)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .clipped()

            Text(unit)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
