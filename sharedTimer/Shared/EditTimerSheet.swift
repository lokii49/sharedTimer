//
//  EditTimerSheet.swift
//  Shared (app + Messages, owner's pick 3A)
//

import SwiftUI

/// Rename a timer/countdown, flip its Alarm/Vibrate toggles, or move a countdown's
/// target date — in place, keeping its id, CloudLink and share links. A timer's time
/// changes through +1:00/Extend, so its length wheel isn't offered here. Sequences are
/// never edited (see `TimerPayload.edited`); callers hide the entry point for them.
struct EditTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The copy the sheet opened with, frozen like the field values below. A plain `let`
    /// was replaced whenever the presenter re-rendered (the detail screen passes its live
    /// payload, refreshed by every store change), while the fields kept their first
    /// values — so a rename or extend landing meanwhile made untouched fields compare as
    /// "changed", and Save wrote the old values back over it.
    @State private var original: TimerPayload
    let onSave: (TimerPayload) -> Void
    /// App: AlarmKit denied (`AlarmController.fullScreenAlarmsDenied`, app only).
    var fullScreenAlarmsOff = false
    /// Messages: an extension can't use AlarmKit, so the footnote says it notifies.
    var notificationOnlyHere = false
    /// Messages, for a timer the app arms through AlarmKit: an Alarm/Vibrate change made
    /// here only reaches that full-screen alarm once Timer opens (owner's call).
    var alarmChangeWaitsForApp = false
    /// App only (N5): tags and the note, kept on this phone. Messages doesn't show them.
    var showsTagsAndNote = false
    @State private var tagIDs: [String] = []
    @State private var originalTagIDs: [String] = []
    @State private var note = ""
    @State private var originalNote = ""
    /// N13: nil = unchanged, .some(nil) = back to the sky, .some(data) = a new photo.
    @State private var photoChange: Data?? = nil
    @State private var pickedPreview: UIImage?

    @State private var label: String
    @State private var kind: TimerKind
    @State private var minutes: Double
    @State private var targetDate: Date
    @State private var alarmEnabled: Bool
    @State private var vibrationEnabled: Bool
    @State private var reminders: Set<TimerReminder> = []
    @State private var originalReminders: Set<TimerReminder> = []
    @FocusState private var labelFocused: Bool

    init(payload: TimerPayload, fullScreenAlarmsOff: Bool = false, notificationOnlyHere: Bool = false,
         alarmChangeWaitsForApp: Bool = false, showsTagsAndNote: Bool = false, onSave: @escaping (TimerPayload) -> Void) {
        _original = State(initialValue: payload)
        self.onSave = onSave
        self.fullScreenAlarmsOff = fullScreenAlarmsOff
        self.notificationOnlyHere = notificationOnlyHere
        self.alarmChangeWaitsForApp = alarmChangeWaitsForApp
        self.showsTagsAndNote = showsTagsAndNote
        let organizer = TimerTagStore.load()
        let tags = organizer.tags(for: payload.id).map(\.id)
        _tagIDs = State(initialValue: tags)
        _originalTagIDs = State(initialValue: tags)
        _note = State(initialValue: organizer.note(for: payload.id) ?? "")
        _originalNote = State(initialValue: organizer.note(for: payload.id) ?? "")
        _label = State(initialValue: payload.label)
        _kind = State(initialValue: payload.kind)
        _minutes = State(initialValue: payload.duration / 60)
        _targetDate = State(initialValue: payload.endDate)
        _alarmEnabled = State(initialValue: payload.alarmEnabled)
        _vibrationEnabled = State(initialValue: payload.vibrationEnabled)
        let reminders = TimerReminders.get(payload.id)
        _reminders = State(initialValue: reminders)
        _originalReminders = State(initialValue: reminders)
    }

    private var edited: TimerPayload {
        original.edited(label: label, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled,
                        targetDate: kind == .countdown ? targetDate : nil)
    }

    /// A moved countdown target that has passed while the sheet was open would end the
    /// countdown on Save; a yearly one rolls to its next anniversary instead.
    private func targetStillValid(at date: Date) -> Bool {
        guard kind == .countdown, original.recurrence == nil,
              abs(targetDate.timeIntervalSince(original.endDate)) >= 1 else { return true }
        return targetDate > date
    }

    /// What Save writes: the fields this sheet actually changed, applied to the newest
    /// stored copy rather than the one it opened with — a pause, extend or rename that
    /// landed meanwhile (Live Activity, Watch, CloudKit) would otherwise be overwritten.
    /// nil when the timer was deleted while the sheet was open (Delete for Everyone,
    /// a remote delete): saving then would bring it back as a new local timer.
    private func editedLatest() -> TimerPayload? {
        guard let latest = TimerStore.loadAll().first(where: { $0.id == original.id })?.advancedSequence() else { return nil }
        let movedTarget = kind == .countdown && abs(targetDate.timeIntervalSince(original.endDate)) >= 1
        return latest.edited(
            label: label != original.label ? label : latest.label,
            alarmEnabled: alarmEnabled != original.alarmEnabled ? alarmEnabled : latest.alarmEnabled,
            vibrationEnabled: vibrationEnabled != original.vibrationEnabled ? vibrationEnabled : latest.vibrationEnabled,
            targetDate: movedTarget ? targetDate : nil)
    }

    /// `edited` always restamps `updatedAt`, so compare the fields an edit can change.
    private var hasChanges: Bool {
        timerFieldsChanged || reminders != originalReminders || localExtrasChanged
    }

    /// Tags and note: this phone only, never an "edited" change for everyone.
    private var localExtrasChanged: Bool {
        showsTagsAndNote && (tagIDs != originalTagIDs || note != originalNote || photoChange != nil)
    }

    private var timerFieldsChanged: Bool {
        let next = edited
        return next.label != original.label
            || next.alarmEnabled != original.alarmEnabled
            || next.vibrationEnabled != original.vibrationEnabled
            || next.endDate != original.endDate
    }

    private var photoPreview: UIImage? {
        switch photoChange {
        case .some(.some): return pickedPreview
        case .some(.none): return nil
        case .none: return TimerPhotos.image(for: original.id)
        }
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
                    repeatFrequency: original.recurrence?.frequency,
                    showsTimerLength: false,
                    targetDateDisabled: original.isPaused,
                    fullScreenAlarmsOff: fullScreenAlarmsOff,
                    notificationOnlyHere: notificationOnlyHere,
                    whenItEndsNote: alarmChangeWaitsForApp
                        && (alarmEnabled != original.alarmEnabled || vibrationEnabled != original.vibrationEnabled)
                        ? Text("Open Timer to apply. Until then, its alarm rings as it was set.") : nil,
                    whenItEndsExtra: original.sequence == nil
                        ? AnyView(ReminderChips(kind: kind, span: kind == .timer ? original.span : max(0, targetDate.timeIntervalSince(original.endDate.addingTimeInterval(-original.duration))), selection: $reminders))
                        : nil
                )
                .environment(\.timeZone, timeZone)

                if showsTagsAndNote {
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
                                               photoChange = .some(data)
                                               pickedPreview = TimerPhotos.downscaledJPEG(data).flatMap(UIImage.init(data:))
                                           },
                                           onRemove: { photoChange = .some(nil); pickedPreview = nil })
                    }
                }
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
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button("Save") {
                            guard targetStillValid(at: Date()) else { return }
                            guard TimerStore.loadAll().contains(where: { $0.id == original.id }) else { return dismiss() }
                            TimerReminders.set(reminders, for: original.id)
                            if localExtrasChanged {
                                TimerTagStore.update { organizer in
                                    organizer.setTags(tagIDs, for: original.id)
                                    organizer.setNote(note, for: original.id)
                                }
                                switch photoChange {
                                case .some(.some(let data)): TimerPhotos.save(data, for: original.id)
                                case .some(.none): TimerPhotos.remove(original.id)
                                case .none: break
                                }
                            }
                            if timerFieldsChanged, let edited = editedLatest() {
                                onSave(edited)
                            } else if let latest = TimerStore.loadAll().first(where: { $0.id == original.id }) {
                                // Only the reminders (a setting on this iPhone): re-plan them,
                                // without an "edited" change that would sync to everyone.
                                TimerReminders.sync(latest)
                            }
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(!hasChanges || !targetStillValid(at: context.date))
                    }
                }
            }
        }
    }
}
