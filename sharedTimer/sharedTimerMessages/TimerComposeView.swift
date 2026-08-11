//
//  TimerComposeView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerComposeView: View {
    @State private var label: String = ""
    @State private var kind: TimerKind = .timer
    @State private var minutes: Double = 5
    @State private var targetDate: Date = Date().addingTimeInterval(86400)
    @State private var shareMode: TimerShareMode = .link
    @FocusState private var labelFocused: Bool

    let onStart: (TimerPayload, TimerShareMode) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    labelFocused: $labelFocused
                )

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
                    let payload = TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate)
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

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
