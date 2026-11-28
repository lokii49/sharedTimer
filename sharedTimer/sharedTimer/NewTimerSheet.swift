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
    /// D8 · A: Never (nil) / Daily / Weekly / Monthly / Yearly.
    @State private var repeatFrequency: AnnualRecurrence.Frequency?
    @State private var countdownTimeZone = TimeZone.current
    @State private var showingCalendarImport = false
    @State private var alarmEnabled = true
    @State private var vibrationEnabled = true
    @State private var reminders: Set<TimerReminder> = []
    /// N5: this phone's tags (the list's current filter preselected) and a note.
    @State private var tagIDs: [String] = []
    @State private var note = ""
    /// N13: a picked photo's data (nil = the sky), saved for the new timer on Start.
    @State private var photoData: Data?
    @State private var photoPreview: UIImage?
    @FocusState private var labelFocused: Bool
    @State private var recents: [RecentTimer] = RecentTimersStore.all()

    let onCreate: (TimerPayload) -> Void

    init(initialKind: TimerKind = .timer, initialTagID: String? = nil, onCreate: @escaping (TimerPayload) -> Void) {
        self._kind = State(initialValue: initialKind)
        self._tagIDs = State(initialValue: initialTagID.map { [$0] } ?? [])
        self.onCreate = onCreate
    }

    /// Live preview of the sky this timer will get.
    private var previewPayload: TimerPayload {
        composedPayload
    }

    /// Same rules as Messages' compose (`ComposeRules`).
    private func canStart(at date: Date) -> Bool {
        ComposeRules.canStart(kind: kind, minutes: minutes, targetDate: targetDate, repeatFrequency: repeatFrequency, at: date)
    }

    private var composedPayload: TimerPayload {
        ComposeRules.payload(label: label, kind: kind, minutes: minutes, targetDate: targetDate, repeatFrequency: repeatFrequency,
                             timeZone: countdownTimeZone, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                // One tap starts a recent timer as-is (timers only — a countdown
                // targets a date). Long-press a chip to forget it.
                if kind == .timer && !recents.isEmpty {
                    Section {
                        ChipFlowLayout(spacing: 8) {
                            ForEach(recents) { recent in
                                Button {
                                    let started = recent.payload()
                                    TimerTagStore.update { $0.adopt(timerID: started.id, recentKey: recent.id) }
                                    onCreate(started)
                                    RecentTimersStore.record(recent)
                                    dismiss()
                                } label: {
                                    // A sequence chip carries the loop glyph (D5 · A).
                                    Label {
                                        Text(recent.title)
                                    } icon: {
                                        if recent.isSequence { Image(systemName: recent.symbolName) }
                                    }
                                    .labelStyle(RecentChipLabelStyle())
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(.white.opacity(0.14), in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                // "Pasta 8m" read as "Pasta 8 meters".
                                .accessibilityLabel(recent.isSequence
                                    ? "\(recent.label), sequence, \(Duration.seconds(recent.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))"
                                    : "\(recent.label), \(Duration.seconds(recent.duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))")
                                .accessibilityHint("Starts right away")
                                .contextMenu {
                                    Button(role: .destructive) {
                                        RecentTimersStore.remove(id: recent.id)
                                        recents = RecentTimersStore.all()
                                        RecentTimersSync.refresh()
                                    } label: {
                                        Label("Remove from Recent", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Recent")
                    }
                }

                Section {
                    SkyCard(payload: previewPayload, date: Date())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if kind == .countdown {
                    Section {
                        Button { showingCalendarImport = true } label: {
                            Label("Import from Calendar", systemImage: "calendar")
                        }
                        Picker("Repeat", selection: $repeatFrequency) {
                            Text("Never").tag(AnnualRecurrence.Frequency?.none)
                            ForEach(AnnualRecurrence.Frequency.allCases) { frequency in
                                Text(frequency.pickerTitle).tag(Optional(frequency))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(kind.accentColor)
                    } footer: {
                        if let repeatFrequency { Text(repeatFrequency.composeFooter(targetDate: targetDate, timeZone: countdownTimeZone)) }
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
                    kindLocked: true, yearlyCountdown: repeatFrequency != nil && kind == .countdown,
                    repeatFrequency: kind == .countdown ? repeatFrequency : nil,
                    fullScreenAlarmsOff: AlarmController.fullScreenAlarmsDenied,
                    whenItEndsExtra: AnyView(ReminderChips(kind: kind, span: kind == .timer ? minutes * 60 : max(0, targetDate.timeIntervalSinceNow), selection: $reminders))
                )
                .environment(\.timeZone, countdownTimeZone)

                Section {
                    TagChipsPicker(selection: $tagIDs)
                }
                Section("Note") {
                    TextField("Add a note", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("noteField")
                }
                Section {
                    PhotoBackgroundRow(preview: photoPreview,
                                       onPick: { data in
                                           photoData = data
                                           photoPreview = TimerPhotos.downscaledJPEG(data).flatMap(UIImage.init(data:))
                                       },
                                       onRemove: { photoData = nil; photoPreview = nil })
                }
            }
            .sheet(isPresented: $showingCalendarImport) {
                CalendarImportSheet { choice in
                    label = choice.title
                    targetDate = choice.date
                    countdownTimeZone = choice.timeZone
                    repeatFrequency = choice.repeatsYearly ? .yearly : nil
                }
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
                    // Re-checked every second: a countdown target can pass while the
                    // sheet sits open, and starting then made a 1-second countdown.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button("Start") {
                            guard canStart(at: Date()) else { return }
                            let payload = composedPayload
                            // Set before onCreate: its arm plans the reminders.
                            TimerReminders.set(reminders.filter { $0.fits(span: payload.span) && TimerReminder.choices(for: payload.kind).contains($0) }, for: payload.id)
                            let tags = tagIDs, text = note
                            TimerTagStore.update { organizer in
                                organizer.setTags(tags, for: payload.id)
                                organizer.setNote(text, for: payload.id)
                            }
                            if let photoData { TimerPhotos.save(photoData, for: payload.id) }
                            onCreate(payload)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(!canStart(at: context.date))
                    }
                }
            }
        }
    }
}

/// Icon (when there is one) tight against the title, for the Recent chips.
private struct RecentChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
