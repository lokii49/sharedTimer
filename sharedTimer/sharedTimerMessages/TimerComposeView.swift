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
    /// Never (nil) / Daily / Weekly / Monthly / Yearly, as in the app (owner's pick 1A).
    @State private var repeatFrequency: AnnualRecurrence.Frequency?
    @State private var alarmEnabled = true
    @State private var vibrationEnabled = true
    @State private var shareMode: TimerShareMode = .link
    @State private var activeTimers: [TimerPayload] = TimerStore.loadAll().map { $0.advancedSequence() }.filter { !$0.isExpired }
    @State private var pickedExisting: TimerPayload?
    @FocusState private var labelFocused: Bool

    /// (payload, mode, isExisting) — `isExisting` when re-sharing a picked timer.
    let onStart: (TimerPayload, TimerShareMode, Bool) -> Void

    private func canStart(at date: Date) -> Bool {
        if pickedExisting != nil { return true }
        return ComposeRules.canStart(kind: kind, minutes: minutes, targetDate: targetDate, repeatFrequency: repeatFrequency, at: date)
    }

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
                            // No .buttonStyle(.plain): the default Form/List button style
                            // gives the whole row cell (insets included) a tap target, not
                            // just the label's own rendered content.
                            Button {
                                labelFocused = false
                                pickedExisting = timer
                            } label: {
                                existingRow(timer)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    alarmEnabled: $alarmEnabled,
                    vibrationEnabled: $vibrationEnabled,
                    labelFocused: $labelFocused,
                    yearlyCountdown: repeatFrequency != nil && kind == .countdown,
                    repeatFrequency: kind == .countdown ? repeatFrequency : nil,
                    notificationOnlyHere: true
                )

                if kind == .countdown {
                    Section {
                        Picker("Repeat", selection: $repeatFrequency) {
                            Text("Never").tag(AnnualRecurrence.Frequency?.none)
                            ForEach(AnnualRecurrence.Frequency.allCases) { frequency in
                                Text(frequency.pickerTitle).tag(Optional(frequency))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(kind.accentColor)
                    } footer: {
                        if let repeatFrequency { Text(repeatFrequency.composeFooter(targetDate: targetDate, timeZone: .current)) }
                    }
                }
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
            // Re-checked every second, like the app's New Timer sheet: a 0:00:00 timer or a
            // target that passed while the sheet was open would ring at once.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    guard canStart(at: Date()) else { return }
                    labelFocused = false
                    let toShare = pickedExisting ?? composedPayload
                    onStart(toShare, shareMode, pickedExisting != nil)
                } label: {
                    Label(pickedExisting == nil ? "Start & Share" : "Share", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .disabled(!canStart(at: context.date))
            }
            .padding()
            .background(Sky.room.opacity(0.92))
        }
        .onAppear {
            activeTimers = TimerStore.loadAll().map { $0.advancedSequence() }.filter { !$0.isExpired }
        }
    }

    /// The live preview of the sky the composed timer will get.
    private var previewPayload: TimerPayload {
        pickedExisting ?? composedPayload
    }

    private var composedPayload: TimerPayload {
        ComposeRules.payload(label: label, kind: kind, minutes: minutes, targetDate: targetDate, repeatFrequency: repeatFrequency,
                             alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }

    /// Ticks every second (it used to show the time left when the sheet opened), follows
    /// a sequence into its next phase, and gives a scheduled sequence its start time —
    /// not "Ends" with phase 0's end and a countdown through the wait.
    private func existingRow(_ stored: TimerPayload) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let timer = stored.advancedSequence(at: context.date)
            let start = timer.isPending(at: context.date) ? timer.scheduledStartDate : nil
            let left = timer.pausedRemaining ?? max(0, timer.endDate.timeIntervalSince(context.date))
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Sky.gradient(for: timer))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.label)
                        .font(.body)
                        .lineLimit(1)
                    Group {
                        if let start {
                            Text(Sky.pendingStartText(for: start, at: context.date))
                        } else if timer.isPaused {
                            Text("Paused")
                        } else if timer.kind == .countdown {
                            Text(TimeFormat.targetDate(timer.endDate))
                        } else {
                            Text("Ends \(timer.endDate.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // A scheduled sequence shows its start time, never a countdown to it
                // (the pending state's rule, see CLAUDE.md).
                if start == nil {
                    Text(TimeFormat.display(left))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
    }
}
