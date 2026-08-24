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
    @State private var activeTimers: [TimerPayload] = TimerStore.loadAll().filter { !$0.isExpired }
    @State private var pickedExisting: TimerPayload?
    @FocusState private var labelFocused: Bool

    let onStart: (TimerPayload, TimerShareMode) -> Void

    var body: some View {
        Form {
            Section {
                SkyCard(payload: previewPayload, date: Date())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let picked = pickedExisting {
                Section {
                    existingRow(picked)
                } header: {
                    Text("Sharing")
                } footer: {
                    Button("Choose a different timer") {
                        pickedExisting = nil
                    }
                    .font(.footnote)
                }
            } else {
                if !activeTimers.isEmpty {
                    Section("Share a running timer") {
                        ForEach(activeTimers) { timer in
                            Button {
                                labelFocused = false
                                pickedExisting = timer
                            } label: {
                                existingRow(timer)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    labelFocused: $labelFocused
                )
            }

            Section {
                Picker("Share as", selection: $shareMode) {
                    Text("Link").tag(TimerShareMode.link)
                    Text("App Card").tag(TimerShareMode.appCard)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(shareMode == .appCard
                     ? "A richer bubble, but it only works if your friend has Timer too."
                     : "A plain link that opens for anyone, app or not.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Sky.room)
        .safeAreaInset(edge: .bottom) {
            Button {
                labelFocused = false
                let toShare = pickedExisting ?? TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate)
                onStart(toShare, shareMode)
            } label: {
                Label(pickedExisting == nil ? "Start & Share" : "Share", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassPill)
            .padding()
            .background(Sky.room.opacity(0.92))
        }
        .onAppear {
            activeTimers = TimerStore.loadAll().filter { !$0.isExpired }
        }
    }

    /// The live preview of the sky the composed timer will get.
    private var previewPayload: TimerPayload {
        pickedExisting ?? TimerPayload.compose(
            label: label.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : label,
            kind: kind, minutes: minutes, targetDate: targetDate)
    }

    private func existingRow(_ timer: TimerPayload) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Sky.gradient(for: timer))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.body)
                    .lineLimit(1)
                Text(timer.isPaused
                     ? "Paused"
                     : (timer.kind == .countdown
                        ? TimeFormat.targetDate(timer.endDate)
                        : "Ends \(timer.endDate.formatted(date: .omitted, time: .shortened))"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeFormat.display(timer.remaining))
                .font(.body.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
