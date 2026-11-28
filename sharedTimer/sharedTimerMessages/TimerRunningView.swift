//
//  TimerRunningView.swift
//  sharedTimerMessages
//

import Combine
import SwiftUI
import UIKit

struct TimerRunningView: View {
    static let storeChange = Notification.Name("SharedTimerMessagesStoreChange")
    /// Whether this timer was in the store when the view appeared — only then does its
    /// disappearance mean "deleted" (a bubble can show a timer that was never stored).
    @State private var wasStored = false
    @State private var payload: TimerPayload
    let onNewTimer: () -> Void
    let onUpdate: (TimerPayload, String) -> Void
    let onDelete: (TimerPayload) -> Void
    /// M11 (owner's pick A): sends this timer's current state as a new App Card from
    /// its own bubble, so it continues that card's session and Messages collapses the
    /// older card (the collapse needs the card selected — seen in the simulator).
    let onSendUpdate: (TimerPayload) -> Void
    @State private var participantCount: Int?
    @State private var hasBuzzedFinish = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    init(payload: TimerPayload,
         onNewTimer: @escaping () -> Void,
         onUpdate: @escaping (TimerPayload, String) -> Void,
         onDelete: @escaping (TimerPayload) -> Void,
         onSendUpdate: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onNewTimer = onNewTimer
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onSendUpdate = onSendUpdate
    }

    /// Shared with this phone as view only, and whether it was shared by someone else
    /// at all — both re-read when CloudKit reports a permission change.
    @State private var readOnly = false
    @State private var isParticipant = false
    @State private var showingCustomExtend = false
    @State private var isShared = false
    @State private var confirmingDeleteForEveryone = false
    @State private var showingEdit = false
    /// The finish "Done" was tapped for here, so the count and the pill go at once.
    @State private var acknowledgedEnd: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
            let pending = payload.isPending(at: context.date)
            // Stop or Done (here or in the app) ends the count, as everywhere else.
            let acknowledged = acknowledgedEnd == payload.endDate || TimerStore.isFinishAcknowledged(id: payload.id)
            let overtime = done ? Sky.overtimeText(for: payload, at: context.date, acknowledged: acknowledged) : nil

            ZStack {
                Sky.gradient(for: payload, at: context.date)
                    .ignoresSafeArea()

                // Edit (owner's pick 3A): the app's sheet; not for sequences. On a view-only
                // share it's shown but disabled, like Pause (the mockup's rule).
                if payload.sequence == nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button { showingEdit = true } label: {
                                Image(systemName: "pencil")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular.interactive(), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(readOnly)
                            .opacity(readOnly ? 0.45 : 1)
                            .accessibilityLabel("Edit")
                            .padding(.trailing, 16)
                            .padding(.top, 12)
                        }
                        Spacer()
                    }
                }

                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Text(payload.label)
                            .skyLabel(12)
                            .foregroundStyle(.white.opacity(0.85))
                        if let recurrence = payload.recurrence { Text(recurrence.frequency.repeatsCaption).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                        if let caption = payload.sequenceCaption {
                            Text(pending ? Sky.pendingSequenceCaption(payload.sequence!) : caption)
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                        Text(pending ? Sky.pendingStartText(for: payload.scheduledStartDate!, at: context.date) : overtime ?? TimeFormat.display(remaining))
                            .skyDigits(52, weight: .thin)
                            .foregroundStyle(overtime == nil ? Color.white : Sky.overtimeInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 20)
                            // Text, not String: a String branch here made the whole label
                            // a String, and "Starts %@" / "%@ left" stopped being translated.
                            .accessibilityLabel(pending ? Text("Starts \(payload.scheduledStartDate?.formatted(date: .abbreviated, time: .shortened) ?? "")")
                                                : overtime != nil ? Text(verbatim: Sky.overtimeAccessibilityText(for: payload, at: context.date))
                                                : Text("\(Duration.seconds(max(0, remaining.rounded())).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))) left"))
                            .accessibilityAddTraits(.updatesFrequently)
                        Text(subtitle(done: done))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                        // Only a live share stays in step with the friend's copy.
                        if done || isShared {
                            Text(done ? "Timer finished" : "This matches what your friend sees")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.top, 2)
                        }
                        if let participantCount, participantCount > 1 {
                            Text("\(participantCount) watching")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    if alarm.isPlaying || vibration.isVibrating {
                        Button("Stop") {
                            alarm.stop()
                            vibration.stop()
                            // The same acknowledgment as the app's Stop, so neither keeps
                            // counting overtime or alerting for this finish.
                            TimerStore.acknowledgeFinish(id: payload.id)
                        }
                        .buttonStyle(.glassPill)
                    }

                    if isParticipant {
                        // Shared with you: what you may do with it (live — see below).
                        SharePermissionBadge(readOnly: readOnly)
                            .padding(.bottom, 10)
                    }

                    // Same controls, in the same order, as the app's detail screen.
                    HStack(spacing: 12) {
                        // Ends the orange count when nothing is ringing here (owner's
                        // pick A, 2026-11-28). This phone only, so a view-only share keeps it.
                        if overtime != nil && !(alarm.isPlaying || vibration.isVibrating) {
                            Button("Done") { finishOvertime() }
                                .buttonStyle(.glassPill)
                        }
                        Group {
                            if pending {
                                Button("Start Now") { startEarly() }
                                    .buttonStyle(.glassPill)
                            } else if !done {
                                GlassEffectContainer(spacing: 16) {
                                    // As in the app: Pause drops below when the row doesn't fit.
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 12) { timeControls; pauseButton }
                                        VStack(spacing: 12) { timeControls; pauseButton }
                                    }
                                }
                            } else {
                                Button("Repeat") { repeatTimer() }
                                    .buttonStyle(.glassPill)
                            }
                        }
                        // View only: shown but disabled, so it's clear why they don't work.
                        .disabled(readOnly)
                        .opacity(readOnly ? 0.45 : 1)
                    }

                    // A repeating countdown: skip to its next occurrence, like the app's
                    // detail screen ("Next Year", "Next Week", …).
                    if let recurrence = payload.recurrence, !pending {
                        Button(String(localized: recurrence.frequency.nextTitle)) { skipOccurrence() }
                            .buttonStyle(.glassPill)
                            .padding(.top, 10)
                            .disabled(readOnly)
                            .opacity(readOnly ? 0.45 : 1)
                    }

                    Button(String(localized: "Send update")) {
                        // The newest stored copy, like every other tap here.
                        onSendUpdate(TimerStore.loadAll().first { $0.id == payload.id }?.advancedSequence() ?? payload)
                    }
                    .buttonStyle(.glassPill)
                    .padding(.top, 10)

                    HStack(spacing: 22) {
                        Button {
                            onNewTimer()
                        } label: {
                            Label("New Timer", systemImage: "plus.circle")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        // Same words and confirmation as the app: the owner of a shared
                        // timer deletes it for everyone, anyone else removes their copy.
                        Button {
                            if isShared && !isParticipant {
                                confirmingDeleteForEveryone = true
                            } else {
                                onDelete(payload)
                            }
                        } label: {
                            Text(isShared ? (isParticipant ? String(localized: "Remove from My Timers") : String(localized: "Delete for Everyone"))
                                          : String(localized: "Delete"))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .confirmationDialog(String(localized: "Delete for everyone?"), isPresented: $confirmingDeleteForEveryone, titleVisibility: .visible) {
                            Button(String(localized: "Delete for Everyone"), role: .destructive) { onDelete(payload) }
                        } message: {
                            Text("It stops for everyone you shared it with.")
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                }
            }
            // TimelineView localizes invalidation to this closure — a modifier attached
            // outside it (below) only re-evaluates on @State changes, never on the tick
            // that actually crosses zero. `done` is recomputed fresh every tick, so
            // .onChange has to live in here to see the flip.
            .onChange(of: done) { _, isExpired in
                guard isExpired, !hasBuzzedFinish else { return }
                hasBuzzedFinish = true
                if payload.alarmEnabled { alarm.start() }
                // Independent of the alarm path — vibration has its own toggle.
                if payload.vibrationEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    vibration.start()
                }
                if payload.sequence != nil || payload.recurrence != nil {
                    payload = payload.advancedSequence(at: context.date)
                    onUpdate(payload, "sequenceAdvanced")
                    hasBuzzedFinish = payload.isExpired
                }
            }
        }
        .onAppear {
            refreshPermissionState()
            // Opening a bubble of a timer already shared with this phone: re-check now,
            // rather than wait for the main app or the 30s check below.
            if isParticipant {
                CloudSyncController.refreshPermissions(for: [payload.id]) { refreshPermissionState() }
            }
        }
        // Presented from here, outside the 1s TimelineView's running branch, so it stays
        // open if the timer ends mid-pick (the add is then skipped).
        .sheet(isPresented: $showingCustomExtend) {
            CustomExtendSheet { interval in
                if !payload.isFinished { extend(by: interval) }
            }
            // A sheet doesn't inherit the controller's forced dark style.
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingEdit) {
            EditTimerSheet(payload: payload, notificationOnlyHere: true,
                           alarmChangeWaitsForApp: TimerStore.isAlarmKitArmed(id: payload.id)) { edited in
                // Same path as Pause and +1:00: the view-only re-check first.
                guard latestForChange() != nil else { return }
                // As the app's applyEdit: a finished countdown moved into the future
                // stops ringing and can ring again at its new end.
                if payload.isFinished && !edited.isFinished {
                    alarm.stop()
                    vibration.stop()
                    hasBuzzedFinish = false
                }
                payload = edited
                onUpdate(edited, "edited")
            }
            .preferredColorScheme(.dark)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.permissionsChanged)) { _ in
            refreshPermissionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.sharingChanged)) { _ in
            refreshPermissionState()
        }
        // The owner can change it while this is open; a delayed silent push is covered
        // by re-checking every 30s.
        .task(id: isParticipant) {
            guard isParticipant else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                CloudSyncController.refreshPermissions(for: [payload.id]) { refreshPermissionState() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.storeChange).merge(with: NotificationCenter.default.publisher(for: CloudSyncController.revertedToServer))) { _ in
            reloadFromStore()
        }
        // Other processes change the store while this stays open — a Live Activity or
        // Siri pause (run in the app), the Watch relay, the notification service saving a
        // friend's pause — and nothing tells this extension. Before, it kept counting the
        // old copy, rang at the old end, and a tap pushed that stale copy over the change.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if let stored = TimerStore.loadAll().first(where: { $0.id == payload.id }), payload.hasOutsideChange(stored) {
                    reloadFromStore()
                } else if wasStored, !TimerStore.loadAll().contains(where: { $0.id == payload.id }) {
                    reloadFromStore()
                }
            }
        }
        .onAppear {
            wasStored = TimerStore.loadAll().contains { $0.id == payload.id }
            payload = payload.advancedSequence()
            hasBuzzedFinish = payload.isExpired
            CloudSyncController.fetchParticipantCount(for: payload) { participantCount = $0 }
        }
        .onDisappear {
            // The Messages extension's own compact/expanded lifecycle can tear this
            // view down while the alarm is still looping (user swipes to another app
            // in the conversation) — nothing else would stop it.
            alarm.stop()
            vibration.stop()
        }
    }

    private func subtitle(done: Bool) -> String {
        if payload.isPending(), let sequence = payload.sequence { return Sky.pendingFirstPhaseText(sequence) ?? String(localized: "Scheduled") }
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

    private func reloadFromStore() {
        refreshPermissionState()
        if let stored = TimerStore.loadAll().first(where: { $0.id == payload.id }) {
            payload = stored.advancedSequence()
            hasBuzzedFinish = payload.isExpired
            if payload.isPaused || !payload.isExpired { alarm.stop(); vibration.stop() }
        } else if wasStored {
            // Deleted meanwhile (a remote delete, or elsewhere on this phone): leave it,
            // or its Pause/+1:00 saved the deleted timer back into the store.
            alarm.stop()
            vibration.stop()
            onNewTimer()
        }
    }

    /// The copy a tap changes: the newest stored one (another process may have changed
    /// it since the last reload), and nil — with the controls disabled — if the share
    /// turned view only meanwhile (the change would be refused after this view had
    /// already shown it).
    private func latestForChange() -> TimerPayload? {
        refreshPermissionState()
        guard !readOnly else { return nil }
        return (TimerStore.loadAll().first(where: { $0.id == payload.id }) ?? payload).advancedSequence()
    }

    private func skipOccurrence() {
        guard let base = latestForChange(), let skipped = base.skippingOccurrence(endingAt: base.endDate) else { return }
        alarm.stop()
        vibration.stop()
        hasBuzzedFinish = false
        payload = skipped
        onUpdate(payload, "advanced")
    }

    private func refreshPermissionState() {
        readOnly = TimerStore.isReadOnly(id: payload.id)
        let link = CloudLinkStore.get(timerID: payload.id)
        isShared = link?.isShared == true
        isParticipant = link?.isOwner == false
    }

    private func togglePause() {
        guard let base = latestForChange() else { return }
        payload = base.isPaused ? base.resumed() : base.paused()
        onUpdate(payload, payload.isPaused ? "paused" : "resumed")
    }

    private func extend(by interval: TimeInterval) {
        guard let base = latestForChange(), !base.isFinished else { return }
        payload = base.extended(by: interval)
        onUpdate(payload, "extended")
    }

    private var timeControls: some View {
        ExtendTimeMenu(onExtend: { extend(by: $0) }, onCustom: { showingCustomExtend = true },
                       canRemove: { payload.canShorten(by: $0) },
                       onRemove: payload.recurrence == nil ? { remove($0) } : nil)
    }

    private var pauseButton: some View {
        Button(payload.isPaused ? "Resume" : "Pause") { togglePause() }
            .buttonStyle(.glassPill)
    }

    private func remove(_ interval: TimeInterval) {
        guard let base = latestForChange(), let shorter = base.shortened(by: interval) else { return }
        payload = shorter
        onUpdate(payload, "shortened")
    }

    private func startEarly() {
        guard let base = latestForChange() else { return }
        payload = base.repeated()
        onUpdate(payload, "startedEarly")
    }

    /// "Done": the same acknowledgment as Stop (no save, no push — this phone only), and
    /// the finished card goes instead of counting for its last minutes.
    private func finishOvertime() {
        acknowledgedEnd = payload.endDate
        TimerStore.acknowledgeFinish(id: payload.id)
        LiveActivityController.end(id: payload.id)
    }

    private func repeatTimer() {
        guard let base = latestForChange() else { return }
        alarm.stop()
        vibration.stop()
        hasBuzzedFinish = false
        payload = base.repeated()
        onUpdate(payload, "repeated")
    }
}
