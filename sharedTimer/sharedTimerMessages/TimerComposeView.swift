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
    /// Heads-up reminders for this phone (owner's pick 5A), as in the app.
    @State private var reminders: Set<TimerReminder> = []
    @State private var shareMode: TimerShareMode = .link
    @State private var activeTimers: [TimerPayload] = TimerStore.loadAll().map { $0.advancedSequence() }.filter { !$0.isExpired }
    @State private var pickedExisting: TimerPayload?
    /// Templates saved in the app (owner's pick 2A): one tap starts and shares one.
    /// Building or editing sequences stays in the app.
    @State private var savedSequences: [SavedSequence] = SavedSequenceStore.loadAll()
    @FocusState private var labelFocused: Bool

    /// Just removed from its bubble's view (owner's pick 4A): an Undo shows for 5 s.
    /// The controller keeps the real window and finishes it on its own.
    var removed: TimerPayload? = nil
    var onUndo: () -> Void = {}
    @State private var undoVisible = true

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

                if !savedSequences.isEmpty {
                    Section("Your sequences") {
                        ForEach(savedSequences) { saved in
                            savedSequenceRow(saved)
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
                    notificationOnlyHere: true,
                    whenItEndsExtra: AnyView(ReminderChips(kind: kind, span: kind == .timer ? minutes * 60 : max(0, targetDate.timeIntervalSinceNow), selection: $reminders))
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
            VStack(spacing: 10) {
            if let removed, undoVisible {
                HStack {
                    Text("Removed “\(removed.label)”")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") {
                        undoVisible = false
                        onUndo()
                    }
                    .buttonStyle(.glassPill)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .accessibilityElement(children: .contain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(.easeOut(duration: 0.2)) { undoVisible = false }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    guard canStart(at: Date()) else { return }
                    labelFocused = false
                    let toShare = pickedExisting ?? composedPayload
                    if pickedExisting == nil {
                        // Set before onStart: its arm plans them. Never for a re-shared timer.
                        TimerReminders.set(reminders.filter { $0.fits(span: toShare.span) && TimerReminder.choices(for: toShare.kind).contains($0) }, for: toShare.id)
                    }
                    onStart(toShare, shareMode, pickedExisting != nil)
                } label: {
                    Label(pickedExisting == nil ? "Start & Share" : "Share", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .disabled(!canStart(at: context.date))
            }
            }
            .padding()
            .background(Sky.room.opacity(0.92))
        }
        .onAppear {
            activeTimers = TimerStore.loadAll().map { $0.advancedSequence() }.filter { !$0.isExpired }
            savedSequences = SavedSequenceStore.loadAll()
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

    /// A saved template: Start composes a fresh run from it and shares it like Start &
    /// Share. One too big for a share link is shown, but can't be started here.
    private func savedSequenceRow(_ saved: SavedSequence) -> some View {
        let payload = saved.shareablePayload()
        return Button {
            guard let fresh = saved.shareablePayload() else { return }
            labelFocused = false
            onStart(fresh, shareMode, false)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(payload.map { Sky.gradient(for: $0) } ?? Sky.gradient(for: previewPayload))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(saved.name).font(.body).lineLimit(1)
                    Text(payload == nil
                         ? String(localized: "Too long to send in Messages")
                         : String(localized: "Phases per loop: \(saved.phases.count) · Loops: \(saved.loopCount)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if payload != nil {
                    Text("Start").fontWeight(.semibold).foregroundStyle((payload?.kind ?? .timer).accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .disabled(payload == nil)
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
