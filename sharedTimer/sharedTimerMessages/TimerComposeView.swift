//
//  TimerComposeView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerComposeView: View {
    @State private var label: String = "Timer"
    @State private var minutes: Double = 5
    @State private var shareMode: TimerShareMode = .link
    @FocusState private var labelFocused: Bool

    let onStart: (TimerPayload, TimerShareMode) -> Void

    private let presets: [Double] = [1, 3, 5, 10, 15, 30, 60]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                card {
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 20)
                        TextField("Label, e.g. Coffee break", text: $label)
                            .focused($labelFocused)
                    }
                }

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

                card {
                    VStack(spacing: 8) {
                        Picker("Share as", selection: $shareMode) {
                            Text("Link").tag(TimerShareMode.link)
                            Text("App Card").tag(TimerShareMode.appCard)
                        }
                        .pickerStyle(.segmented)

                        Text(shareMode == .appCard
                             ? "Nicer bubble, but only works if your friend has SharedTimer too."
                             : "Plain link — opens for anyone, app or not.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                }

                Button {
                    labelFocused = false
                    let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload = TimerPayload(label: name.isEmpty ? "Timer" : name, duration: minutes * 60)
                    onStart(payload, shareMode)
                } label: {
                    Label("Start & Share", systemImage: "paperplane.fill")
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text("New Shared Timer")
                .font(.system(.headline, design: .rounded))
        }
        .padding(.top, 8)
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

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
