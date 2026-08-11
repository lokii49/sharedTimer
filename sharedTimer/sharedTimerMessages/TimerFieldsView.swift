//
//  TimerFieldsView.swift
//  sharedTimerMessages
//

import SwiftUI

/// Shared compose fields for creating a timer or a date-targeted countdown.
/// Embedded by both the Messages compose sheet and the main app's "New" sheet;
/// each host supplies its own trailing action (Start & Share vs. Start).
struct TimerFieldsView: View {
    @Binding var label: String
    @Binding var kind: TimerKind
    @Binding var minutes: Double
    @Binding var targetDate: Date
    var labelFocused: FocusState<Bool>.Binding

    private let presets: [Double] = [1, 3, 5, 10, 15, 30, 60]
    private let datePresets: [(String, TimeInterval)] = [
        ("Tomorrow", 86400),
        ("+1 week", 7 * 86400),
        ("+1 month", 30 * 86400)
    ]

    var body: some View {
        VStack(spacing: 20) {
            card {
                HStack(spacing: 12) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                    TextField("Label, e.g. Coffee break", text: $label)
                        .focused(labelFocused)
                }
            }

            card {
                Picker("Type", selection: $kind) {
                    Text("Timer").tag(TimerKind.timer)
                    Text("Countdown").tag(TimerKind.countdown)
                }
                .pickerStyle(.segmented)
            }

            if kind == .timer {
                card {
                    VStack(spacing: 16) {
                        HStack {
                            Button {
                                minutes = max(1, minutes - 1)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 30))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)

                            Spacer()

                            VStack(spacing: 0) {
                                Text("\(Int(minutes))")
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                Text(Int(minutes) == 1 ? "minute" : "minutes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                minutes = min(180, minutes + 1)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 30))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.orange)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(presets, id: \.self) { m in
                                    presetChip(m)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
            } else {
                card {
                    VStack(spacing: 12) {
                        DatePicker(
                            "Ends",
                            selection: $targetDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)

                        Text("Counting down to \(TimeFormat.targetDate(targetDate))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(datePresets, id: \.0) { title, offset in
                                datePresetChip(title, offset: offset)
                            }
                        }
                    }
                }
            }
        }
    }

    private func presetChip(_ m: Double) -> some View {
        let selected = Int(minutes) == Int(m)
        return Button {
            minutes = m
        } label: {
            Text("\(Int(m))m")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.orange : Color(.tertiarySystemFill))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func datePresetChip(_ title: String, offset: TimeInterval) -> some View {
        Button {
            targetDate = Date().addingTimeInterval(offset)
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemFill))
                .foregroundStyle(.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
