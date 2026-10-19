//
//  TimerDetailView.swift
//  sharedTimer
//

import SwiftUI
import UIKit

/// Tap-through detail: the timer's sky, full-bleed and slowly swaying, with the time
/// glowing in the middle and frosted controls floating at the bottom.
struct TimerDetailView: View {
    @State private var payload: TimerPayload
    let onUpdate: (TimerPayload, String) -> Void
    /// The tick's own sequence advance — (payload, rearm). See ContentView.apply.
    let onSequenceAdvance: (TimerPayload, Bool) -> Void
    let onDelete: (TimerPayload) -> Void
    let onShare: (TimerPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var participantCount: Int?
    @State private var attribution: (name: String, action: String)?
    @State private var hasBuzzedFinish = false
    @State private var showingEdit = false
    @State private var confirmingDeleteForEveryone = false
    /// Shared with this phone as view only — see TimerStore.isReadOnly.
    @State private var readOnly = false
    /// Shared with this phone by someone else (shows the permission badge).
    @State private var isParticipant = false
    @State private var showingSaveTemplate = false
    @State private var templateName = ""
    /// Flipped on save so the bookmark redraws as filled.
    @State private var templateSaved = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    init(payload: TimerPayload, onUpdate: @escaping (TimerPayload, String) -> Void, onSequenceAdvance: @escaping (TimerPayload, Bool) -> Void, onDelete: @escaping (TimerPayload) -> Void, onShare: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onUpdate = onUpdate
        self.onSequenceAdvance = onSequenceAdvance
        self.onDelete = onDelete
        self.onShare = onShare
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
            let pending = payload.isPending(at: context.date)
            // The sway: gradient anchors drift on a slow sine, one step per second,
            // smoothed by the animation below — the sky never sits perfectly still.
            let phase = reduceMotion ? 0 : sin(context.date.timeIntervalSinceReferenceDate / 19)
            let colors = Sky.colors(for: payload, at: context.date)

            ZStack {
                LinearGradient(
                    colors: colors,
                    startPoint: UnitPoint(x: 0.15 + 0.1 * phase, y: 0),
                    endPoint: UnitPoint(x: 0.85 - 0.1 * phase, y: 1)
                )
                .ignoresSafeArea()
                .animation(.linear(duration: 1), value: phase)
                // Same "not live yet" muting as SkyCard's row treatment.
                .saturation(pending ? 0.35 : 1)
                .brightness(pending ? -0.1 : 0)

                // Scrolls only when it must (largest text sizes, small phones), so the
                // remove button at the bottom is never cut off; otherwise the spacers
                // centre everything as before.
                GeometryReader { geometry in
                ScrollView {
                VStack {
                    Spacer()

                    VStack(spacing: 10) {
                        Text(payload.label)
                            .skyLabel(13)
                            .foregroundStyle(.white.opacity(0.85))
                        // "Phase 1 of 2 · Loop 1 of 7" would misread as already running.
                        if pending, let sequence = payload.sequence {
                            Text(Sky.pendingSequenceCaption(sequence))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        } else if let caption = payload.sequenceCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(pending ? (payload.scheduledStartDate.map { Sky.pendingStartText(for: $0, at: context.date) } ?? "") : TimeFormat.display(remaining))
                            .skyDigits(72, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 24)
                            .accessibilityLabel(pending ? "Starts \(payload.scheduledStartDate?.formatted(date: .abbreviated, time: .shortened) ?? "")"
                                                : "\(Duration.seconds(max(0, remaining.rounded())).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))) left")
                            .accessibilityAddTraits(.updatesFrequently)
                        Text(subtitle(done: done, pending: pending))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                        if let recurrence = payload.recurrence {
                            Text("Repeats yearly · \(recurrence.timeZoneID)")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        if let statusLine {
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    if isParticipant {
                        // Someone shared this with you: say what you may do with it.
                        // Updates live when the owner changes it in Manage Sharing.
                        SharePermissionBadge(readOnly: readOnly)
                            .padding(.bottom, 14)
                    }

                    // View-only share: the change controls stay in place but disabled
                    // (owner's choice — visible, so it's clear why nothing happens);
                    // Stop, which only silences this phone, and remove stay enabled.
                    if pending {
                        // Pause/Extend don't mean anything before the scheduled start
                        // actually begins; Delete (below, unconditional) is Cancel.
                        Button("Start Now") {
                            startEarly()
                        }
                        .buttonStyle(.glassPill)
                        .disabled(readOnly)
                        .opacity(readOnly ? 0.45 : 1)
                    } else if !done {
                        HStack(spacing: 12) {
                            ExtendTimeMenu { extend(by: $0) }

                            Button(payload.isPaused ? "Resume" : "Pause") {
                                togglePause()
                            }
                            .buttonStyle(.glassPill)
                        }
                        .disabled(readOnly)
                        .opacity(readOnly ? 0.45 : 1)
                    } else {
                        HStack(spacing: 12) {
                            if alarm.isPlaying || vibration.isVibrating {
                                Button("Stop") {
                                    alarm.stop()
                                    vibration.stop()
                                    // Same acknowledgment the notification's own "Stop"
                                    // action writes — keeps the two Stop paths consistent.
                                    TimerStore.acknowledgeFinish(id: payload.id)
                                }
                                .buttonStyle(.glassPill)
                            }
                            Button("Repeat") {
                                repeatTimer()
                            }
                            .buttonStyle(.glassPill)
                            .disabled(readOnly)
                            .opacity(readOnly ? 0.45 : 1)
                        }
                    }

                    if payload.recurrence != nil {
                        Button("Next Year") {
                            Task { await LiveActivityActions.advanceAnnual(timerID: payload.id, occurrenceEnd: payload.endDate.timeIntervalSince1970) }
                        }
                        .buttonStyle(.glassPill)
                        .padding(.top, 12)
                        .disabled(readOnly)
                        .opacity(readOnly ? 0.45 : 1)
                    }

                    Button(role: .destructive) {
                        if removal == .deleteForEveryone {
                            confirmingDeleteForEveryone = true
                        } else {
                            onDelete(payload)
                            dismiss()
                        }
                    } label: {
                        Text(removal.title)
                    }
                    .buttonStyle(.glassPill)
                    .accessibilityIdentifier("Delete")
                    .confirmationDialog(String(localized: "Delete for everyone?"), isPresented: $confirmingDeleteForEveryone, titleVisibility: .visible) {
                        Button(String(localized: "Delete for Everyone"), role: .destructive) {
                            onDelete(payload)
                            dismiss()
                        }
                    } message: {
                        Text("It stops for everyone you shared it with.")
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                // Full width too: inside a ScrollView the stack shrinks to its content
                // and everything slid to the leading edge.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                }
            }
            // TimelineView localizes invalidation to this closure — a modifier attached
            // outside it (below) only re-evaluates on @State changes, never on the tick
            // that actually crosses zero. `done` is recomputed fresh every tick, so
            // .onChange has to live in here to see the flip.
            .onChange(of: done) { _, isExpired in
                guard isExpired, !hasBuzzedFinish else { return }
                hasBuzzedFinish = true
                // ContentView's own root-level check also catches this zero-crossing
                // while this screen is pushed, but AlarmPlayer/VibrationPlayer.start()
                // no-op when already running, so calling again here is free — don't
                // rely on the (unverified) assumption that the ancestor TimelineView
                // keeps ticking behind an active NavigationStack push.
                // Only sound/vibrate the in-app loop where the app itself owns the
                // alert (see AlarmController.shouldSoundInAppAlarm/shouldVibrateInApp,
                // and checkForNewlyExpired for why this can't key on alarm-dismissed
                // state).
                if AlarmController.shouldSoundInAppAlarm(for: payload) {
                    alarm.start()
                }
                if AlarmController.shouldVibrateInApp(for: payload) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vibration.start()
                }
                // This view holds its own @State copy, seeded once when pushed, so it
                // needs the same advance-and-reseed ContentView's checkForNewlyExpired
                // does — nothing else refreshes it on a plain tick. Same no-rearm rule
                // as there while AlarmKit owns the alert (see
                // AlarmController.alarmKitOwnsAlert): the next phases are pre-armed, and
                // touching AlarmKit here could race the alert it's presenting.
                if payload.sequence != nil || payload.recurrence != nil {
                    let advanced = payload.advancedSequence()
                    let rearm = payload.recurrence != nil || !AlarmController.alarmKitOwnsAlert(for: payload)
                    payload = advanced
                    onSequenceAdvance(advanced, rearm)
                    // Not exhausted -> a new phase just started and can finish again
                    // later; let it re-buzz on that future zero-crossing.
                    hasBuzzedFinish = advanced.isExpired
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if payload.sequence == nil && !readOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingEdit = true } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit")
                }
            }
            if let sequence = payload.sequence {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        templateName = SavedSequenceStore.suggestedName(for: sequence)
                        showingSaveTemplate = true
                    } label: {
                        Image(systemName: SavedSequenceStore.contains(sequence) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(SavedSequenceStore.contains(sequence) ? "Saved as Template" : "Save as Template")
                    .disabled(templateSaved || SavedSequenceStore.contains(sequence))
                }
            }
            if payload.sequence.map(TimerSequenceWire.isValid) ?? true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onShare(payload) } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .alert("Save as Template", isPresented: $showingSaveTemplate) {
            TextField("Name", text: $templateName)
            Button("Save") {
                if let sequence = payload.sequence {
                    SavedSequenceStore.add(sequence, name: templateName)
                    templateSaved = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Start it again any time from New Sequence → Start from.")
        }
        .sheet(isPresented: $showingEdit) {
            EditTimerSheet(payload: payload) { edited in
                applyEdit(edited)
            }
        }
        .onAppear {
            hasBuzzedFinish = payload.isExpired
            readOnly = TimerStore.isReadOnly(id: payload.id)
            isParticipant = CloudLinkStore.get(timerID: payload.id)?.isOwner == false
            CloudSyncController.refreshPermissions(for: [payload.id]) {
                readOnly = TimerStore.isReadOnly(id: payload.id)
            }
            CloudSyncController.fetchParticipantCount(for: payload) { participantCount = $0 }
            CloudSyncController.fetchAttribution(for: payload) { attribution = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.permissionsChanged)) { _ in
            readOnly = TimerStore.isReadOnly(id: payload.id)
        }
        // Fallback for a delayed silent push: while someone it was shared with is
        // looking at it, re-check the permission every 30s.
        .task(id: isParticipant) {
            guard isParticipant else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                CloudSyncController.refreshPermissions(for: [payload.id]) {
                    readOnly = TimerStore.isReadOnly(id: payload.id)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalTimerStoreChange)) { _ in
            // This view holds its own @State copy of payload (seeded once when pushed),
            // so a watch-relayed pause or CloudKit push landing while this exact screen is
            // open would otherwise sit invisible until the user backs out and re-enters —
            // ContentView's own reload (TimerStore.loadAll() into its `timers` array)
            // doesn't touch this already-pushed view's local copy at all.
            readOnly = TimerStore.isReadOnly(id: payload.id)
            guard let fresh = TimerStore.loadAll().first(where: { $0.id == payload.id }) else { return }
            payload = fresh
        }
    }

    /// What the remove button does, which depends on who's looking: the owner of a
    /// shared timer deletes it for everyone (CloudSyncController.pushDelete), someone
    /// it was shared with only removes their own copy, a local timer is just deleted.
    private enum Removal {
        case delete, removeMine, deleteForEveryone
        var title: String {
            switch self {
            case .delete: return String(localized: "Delete")
            case .removeMine: return String(localized: "Remove from My Timers")
            case .deleteForEveryone: return String(localized: "Delete for Everyone")
            }
        }
    }

    private var removal: Removal {
        guard let link = CloudLinkStore.get(timerID: payload.id) else { return .delete }
        return link.isOwner ? .deleteForEveryone : .removeMine
    }

    private func subtitle(done: Bool, pending: Bool = false) -> String {
        // The big digits above already show the start date/time -- repeating it here
        // ("Starts Sun, 3:00 PM") is the exact duplication SkyCard's redesign fixed.
        // What phase 0 actually is fills this slot instead, same as SkyCard's endText.
        if pending, let sequence = payload.sequence, let phaseText = Sky.pendingFirstPhaseText(sequence) {
            return phaseText
        }
        if done {
            return String(localized: "Finished \(payload.endDate.formatted(date: .omitted, time: .shortened))")
        }
        if payload.isPaused {
            return String(localized: "Paused")
        }
        if payload.kind == .countdown {
            return TimeFormat.targetDate(payload.endDate)
        }
        return String(localized: "ends at \(payload.endDate.formatted(date: .omitted, time: .shortened))")
    }

    private func togglePause() {
        payload = payload.isPaused ? payload.resumed() : payload.paused()
        onUpdate(payload, payload.isPaused ? "paused" : "resumed")
    }

    /// Row's own `startEarly` action, mirrored here the same way `togglePause`/`extend`
    /// mirror the row's -- see the row's `startEarly` doc comment for why `repeated()`.
    private func startEarly() {
        payload = payload.repeated()
        onUpdate(payload, "startedEarly")
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload, "extended")
    }

    /// A countdown moved to a future date is running again: silence the finished
    /// alert and let its new zero-crossing buzz, same as `repeatTimer`.
    private func applyEdit(_ edited: TimerPayload) {
        if payload.isFinished && !edited.isFinished {
            alarm.stop()
            vibration.stop()
            hasBuzzedFinish = false
        }
        payload = edited
        onUpdate(edited, "edited")
    }

    /// Restart a finished timer from its detail screen — stop any in-app alarm loop,
    /// re-arm the finish handler, and run the standard mutation path (which reschedules
    /// the AlarmKit alarm / notification and Live Activity).
    private func repeatTimer() {
        alarm.stop()
        vibration.stop()
        hasBuzzedFinish = false
        payload = payload.repeated()
        onUpdate(payload, "repeated")
    }

    /// "2 watching" / "Sam paused" — whichever cloud status has resolved so far; nil
    /// (renders nothing) until the on-demand fetches in .onAppear land, and permanently
    /// nil for a purely local timer.
    private var statusLine: String? {
        var parts: [String] = []
        if let participantCount, participantCount > 1 {
            parts.append(String(localized: "\(participantCount) watching"))
        }
        if let attribution, attribution.name != DisplayNameStore.name {
            parts.append(Self.attributionPhrase(name: attribution.name, action: attribution.action))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The record's `lastAction` is an English wire verb ("paused"), so the whole phrase
    /// is translated, not the verb on its own. An unknown verb (a newer app) shows the
    /// name alone rather than raw English.
    static func attributionPhrase(name: String, action: String) -> String {
        switch action {
        case "created": return String(localized: "\(name) created")
        case "paused": return String(localized: "\(name) paused")
        case "resumed": return String(localized: "\(name) resumed")
        case "extended": return String(localized: "\(name) extended")
        case "repeated": return String(localized: "\(name) repeated")
        case "edited": return String(localized: "\(name) edited")
        case "advanced": return String(localized: "\(name) skipped ahead")
        case "cancelled", "stopped": return String(localized: "\(name) stopped")
        case "startedEarly": return String(localized: "\(name) started early")
        case "updated", "updatedFromLink": return String(localized: "\(name) updated")
        default: return name
        }
    }
}
