//
//  ContentView.swift
//  sharedTimer
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var timers: [TimerPayload] = TimerStore.loadAll()
    @State private var showingNewTimer = false
    @State private var showingNewSequence = false
    @State private var pendingNewTimerKind: TimerKind = .timer
    @State private var sharingPayload: TimerPayload?
    @State private var incomingPayload: TimerPayload?
    @State private var showingNamePrompt = false
    @State private var nameInput: String = ""
    @State private var pendingNameCompletion: (() -> Void)?
    /// Timers observed still running (not yet expired) on some prior tick — an
    /// already-expired timer loaded from the store (stale finish, or one that
    /// arrived via CloudKit already done) never enters this set, so it can't be
    /// mistaken for a fresh zero-crossing and blare the alarm on launch.
    @State private var armedIDs: Set<String> = []
    @State private var showingNotificationPermissionAlert = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Group {
                    if timers.isEmpty {
                        emptyState
                    } else {
                        List {
                            // isFinished, not isExpired: a timer paused exactly at zero is
                            // still "paused" for alarm purposes, but reads as Finished here
                            // rather than sitting in Active forever.
                            let active = timers.filter { !$0.isFinished }.sorted { $0.endDate < $1.endDate }
                            let expired = timers.filter { $0.isFinished }.sorted { $0.endDate > $1.endDate }

                            if !active.isEmpty {
                                Section {
                                    ForEach(active) { row(for: $0, at: context.date) }
                                } header: {
                                    Text("Active").skyLabel().foregroundStyle(Sky.roomInk)
                                }
                            }
                            if !expired.isEmpty {
                                Section {
                                    ForEach(expired) { row(for: $0, at: context.date) }
                                } header: {
                                    Text("Finished").skyLabel().foregroundStyle(Sky.roomInk)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Sky.room)
                    }
                }
                // TimelineView localizes invalidation to this closure (see
                // TimerDetailView's identical comment) — checking for newly-expired
                // active timers has to live in here to see the zero-crossing tick.
                .onChange(of: context.date) { _, date in
                    checkForNewlyExpired(at: date)
                }
            }
            .navigationTitle("Timers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pendingNewTimerKind = .timer
                            showingNewTimer = true
                        } label: {
                            Label("New Timer", systemImage: "timer")
                        }
                        Button {
                            pendingNewTimerKind = .countdown
                            showingNewTimer = true
                        } label: {
                            Label("New Countdown", systemImage: "calendar")
                        }
                        Button {
                            showingNewSequence = true
                        } label: {
                            Label("New Sequence", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewTimer) {
                NewTimerSheet(initialKind: pendingNewTimerKind) { payload in
                    apply(payload)
                }
            }
            .sheet(isPresented: $showingNewSequence) {
                NewSequenceSheet { payload in
                    apply(payload)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickActionTriggered)) { notification in
                // Home Screen Quick Action (long-press the app icon), warm-launch case —
                // app already running, so this subscriber exists when SceneDelegate posts.
                // Cold launch is handled separately in .onAppear (see openQuickAction).
                guard let type = notification.object as? String else { return }
                openQuickAction(type)
            }
            .onReceive(NotificationCenter.default.publisher(for: .externalTimerStoreChange)) { _ in
                // Watch-relayed mutation or CloudKit silent push landed while this view
                // is already foregrounded — scenePhase alone won't fire here since we
                // never left .active. Re-read TimerStore directly.
                timers = TimerStore.loadAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: NotificationScheduler.permissionDeniedNotification)) { _ in
                showingNotificationPermissionAlert = true
            }
            .alert("Notifications are off", isPresented: $showingNotificationPermissionAlert) {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("Timers won't alert you while the app is in the background until notifications are allowed.")
            }
            .sheet(item: $sharingPayload) { payload in
                ShareTimerSheet(payload: payload)
            }
            .sheet(item: $incomingPayload) { payload in
                AddSharedTimerSheet(
                    payload: payload,
                    onAdd: { accepted in
                        apply(accepted)
                        incomingPayload = nil
                    },
                    onDismiss: { incomingPayload = nil }
                )
            }
            .alert("What should we call you?", isPresented: $showingNamePrompt) {
                TextField("Your name", text: $nameInput)
                Button("Continue") {
                    let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { DisplayNameStore.name = trimmed }
                    nameInput = ""
                    pendingNameCompletion?()
                    pendingNameCompletion = nil
                }
                Button("Skip", role: .cancel) {
                    pendingNameCompletion?()
                    pendingNameCompletion = nil
                }
            } message: {
                Text("Shown to people you share timers with, like \"Sam paused Pasta.\"")
            }
        }
        .tint(.white)
        .overlay(alignment: .bottom) {
            if alarm.isPlaying || vibration.isVibrating {
                alarmBanner
            }
        }
        .onAppear {
            timers = TimerStore.loadAll()
            // Re-derive every sequence's current phase from scratch before anything
            // else touches `timers` — correct no matter how long the app was closed
            // (even having missed several whole phases), and must run before
            // reconcileRepeat so a legitimately mid-sequence payload never reaches it
            // still reading as merely "finished" (see AlarmController.reconcileRepeat).
            for index in timers.indices where timers[index].sequence != nil {
                let advanced = timers[index].advancedSequence()
                if advanced.endDate != timers[index].endDate || advanced.sequence?.phaseIndex != timers[index].sequence?.phaseIndex {
                    timers[index] = advanced
                    TimerStore.save(advanced)
                }
            }
            // Fold any "Repeat" tapped on a fired timer's AlarmKit panel back in before
            // arming — the arm loop below then re-aligns the alarm to the revived endDate.
            for id in AlarmController.reconcileRepeat(into: &timers) {
                if let revived = timers.first(where: { $0.id == id }) { TimerStore.save(revived) }
            }
            for payload in timers where !payload.isExpired {
                armAlerts(for: payload)
            }
            pullCloudChanges()
            // Cold-launch Quick Action: SceneDelegate's willConnectTo runs before this
            // .onAppear (and before .onReceive's subscriber exists), so it buffers the
            // shortcut type in a static var instead of posting — drain it here.
            if let type = SceneDelegate.pendingShortcutType {
                SceneDelegate.pendingShortcutType = nil
                openQuickAction(type)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // No background-audio entitlement — the AVAudioPlayer loop would be cut
                // off by the OS anyway; stop it explicitly so isPlaying/the banner don't
                // linger in a stale "still ringing" state. The scheduled notification's
                // own alarm.caf sound covers the backgrounded case. `.inactive` (a
                // Control Center pull, app-switcher peek) is deliberately excluded here —
                // that's a transient gesture, not a real backgrounding, and shouldn't
                // silently kill a ringing alarm.
                alarm.stop()
                vibration.stop()
            }
            guard newPhase == .active else { return }
            // Re-read TimerStore first — a timer created while backgrounded (e.g. via
            // TimerIntents.swift's Siri intents) writes straight to the App Group and has
            // no CloudLink, so pullCloudChanges alone would never surface it here.
            timers = TimerStore.loadAll()
            // Same sequence re-derivation as onAppear, and for the same reason: must
            // run before reconcileRepeat, since a mid-sequence payload sitting
            // un-advanced also reads as `isFinished`.
            for index in timers.indices where timers[index].sequence != nil {
                let advanced = timers[index].advancedSequence()
                if advanced.endDate != timers[index].endDate || advanced.sequence?.phaseIndex != timers[index].sequence?.phaseIndex {
                    timers[index] = advanced
                    TimerStore.save(advanced)
                    armAlerts(for: advanced)
                }
            }
            // Fold any "Repeat" tapped on a fired timer's AlarmKit panel back into the
            // local model, then re-arm ONLY those so the alarm and our copy agree on the
            // endDate — leave every other timer's alarm / Live Activity untouched.
            let revivedIDs = AlarmController.reconcileRepeat(into: &timers)
            if !revivedIDs.isEmpty {
                for id in revivedIDs {
                    if let revived = timers.first(where: { $0.id == id }) {
                        TimerStore.save(revived)
                        armAlerts(for: revived)
                    }
                }
                WatchSyncController.pushCurrentState()
            }
            pullCloudChanges()
            // Opportunistic Live Activity keep-alive: there's no server here to push a
            // periodic refresh while the app isn't running, so a multi-day countdown's
            // activity only survives past iOS's ~8h no-update budget if something re-pushes
            // it — foregrounding the app is the cheapest reliable trigger available.
            // The custom Live Activity only runs where AlarmKit doesn't own one —
            // both toggles off, for either kind (see armAlerts).
            LiveActivityController.refreshAll(from: timers.filter { !AlarmController.ownsAlert(for: $0) })
        }
        .onOpenURL { url in
            handleIncoming(url: url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            handleIncoming(url: activity.webpageURL)
        }
    }

    /// The empty room holds one deep-night sky, waiting.
    private var emptyState: some View {
        ZStack {
            Sky.room.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: Sky.night.stops(drain: 0), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 116)
                    .overlay(alignment: .bottomLeading) {
                        Text("--:--")
                            .skyDigits(30)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(14)
                    }
                    .padding(.horizontal, 24)

                Text("No timers yet")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Tap + to start one, or share a timer from iMessage.")
                    .font(.subheadline)
                    .foregroundStyle(Sky.roomInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    /// Bar shown while the foreground alarm loop (AlarmPlayer) is sounding —
    /// same "Time is up" role the native Clock app's Stop button plays.
    private var alarmBanner: some View {
        HStack {
            Label("Time's up", systemImage: "alarm.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Button("Stop") {
                alarm.stop()
                vibration.stop()
            }
            .buttonStyle(.glassPill)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Fires the foreground alarm loop the moment a timer this screen has actually
    /// watched running (in `armedIDs`) transitions to expired. Only membership in
    /// `armedIDs` — never "loaded already expired" — counts as a zero-crossing, so
    /// a stale finished timer (loaded on launch, or arriving already-done via
    /// CloudKit) can't trigger the alarm. Paused timers are never expired, so they
    /// stay armed and alarm correctly once resumed and run down.
    private func checkForNewlyExpired(at date: Date) {
        let stillRunning = Set(timers.filter { !$0.isExpired }.map(\.id))
        let justFinished = armedIDs.subtracting(stillRunning)
        armedIDs = stillRunning
        guard !justFinished.isEmpty else { return }
        // A payload AlarmKit is handling (alarm on + authorized) gets AlarmKit's own
        // full-screen alert, even in the foreground — running the in-app AVAudioPlayer
        // loop + banner on top of it would double the sound. Only sound the in-app loop
        // where the app itself is the alarm: alarm off, or alarm on with AlarmKit
        // permission denied. A payload AlarmKit handled — even one already stopped
        // from its panel — must not re-bang on app open (shouldSoundInAppAlarm/
        // shouldVibrateInApp key on auth state, not alarm-dismissed state, for exactly
        // this reason).
        let finished = timers.filter { justFinished.contains($0.id) }
        if finished.contains(where: { AlarmController.shouldSoundInAppAlarm(for: $0) }) {
            alarm.start()
        }
        if finished.contains(where: { AlarmController.shouldVibrateInApp(for: $0) }) {
            vibration.start()
        }
        // Sequence payloads: this 1s tick is the only hook that sees a live
        // zero-crossing while the app stays foregrounded — onAppear/scenePhase only
        // fire at launch/backgrounding. Alerts above already fired off the
        // pre-advance (just-ended) phase; advance now, after, so the next phase's own
        // zero-crossing is still detected on a later tick (re-adds its id to
        // `armedIDs` unless the whole sequence just ran out).
        // Skip entirely while AlarmKit itself is presenting this payload's alert —
        // `apply` -> `armAlerts` -> `AlarmController.reschedule` unconditionally
        // cancels the current alarm before deciding whether to reschedule, so
        // advancing here would cancel AlarmKit's own alert out from under the user
        // within this tick, before they can act on its Stop/Next buttons (confirmed on
        // device). Left un-advanced, it stays correctly stale until the user acts on
        // the alert (secondaryIntent's own advance) or next foregrounds the app, both
        // already-correct paths per the re-derivation guarantee.
        for payload in finished where payload.sequence != nil && !AlarmController.alarmKitOwnsAlert(for: payload) {
            let advanced = payload.advancedSequence(at: date)
            apply(advanced, action: "sequenceAdvanced")
            if !advanced.isExpired {
                armedIDs.insert(advanced.id)
            }
        }
    }

    private func row(for payload: TimerPayload, at date: Date) -> some View {
        SkyCard(payload: payload, date: date)
            // Hidden NavigationLink behind the card: a visible one draws the gray
            // disclosure chevron outside the sky, which breaks the full-bleed card.
            .background(
                NavigationLink("") {
                    TimerDetailView(payload: payload, onUpdate: applyMutation, onDelete: delete)
                }
                .opacity(0)
            )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(payload)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            // Explicit tint: with a clear listRowBackground the destructive role's
            // default red fill drops out and the button reveals as a white slab.
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            if payload.isFinished {
                Button {
                    repeatTimer(payload)
                } label: {
                    Label("Repeat", systemImage: "arrow.clockwise")
                }
                .tint(.indigo)
            } else {
                Button {
                    togglePause(payload)
                } label: {
                    Label(payload.isPaused ? "Resume" : "Pause",
                          systemImage: payload.isPaused ? "play.fill" : "pause.fill")
                }
                .tint(.teal)

                Button {
                    extend(payload, by: 60)
                } label: {
                    Label("+1 min", systemImage: "plus")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            // Sequences aren't shareable in v1 — a recipient would only get a
            // one-off snapshot of whichever phase happened to be current. See CLAUDE.md.
            if payload.sequence == nil {
                Button {
                    withDisplayName { sharingPayload = payload }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
            if payload.isFinished {
                Button {
                    repeatTimer(payload)
                } label: {
                    Label("Repeat", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    togglePause(payload)
                } label: {
                    Label(payload.isPaused ? "Resume" : "Pause",
                          systemImage: payload.isPaused ? "play.fill" : "pause.fill")
                }
                Button {
                    extend(payload, by: 60)
                } label: {
                    Label("Add 1 min", systemImage: "plus")
                }
            }
            Button(role: .destructive) {
                delete(payload)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Arms the finished-alert for a payload — an AlarmKit alarm when either the alarm
    /// or vibration toggle is on (rings through silent/Focus, full-screen Stop/Repeat
    /// panel, survives force-quit; either kind now), a local notification only when
    /// both are off — plus the custom Live Activity, which only backs that both-off
    /// case: AlarmKit runs its own Live Activity whenever it owns the alert, so
    /// starting ours too would double it up (the "too many Live Activities" bug). See
    /// AlarmController.ownsAlert. Paused/expired payloads are handled inside
    /// `reschedule`.
    private func armAlerts(for payload: TimerPayload) {
        AlarmController.reschedule(for: payload)
        guard !AlarmController.ownsAlert(for: payload) else { return }
        if payload.isPaused {
            LiveActivityController.update(for: payload)
        } else {
            LiveActivityController.start(for: payload)
        }
    }

    private func delete(_ payload: TimerPayload) {
        TimerStore.delete(id: payload.id)
        AlarmController.clear(id: payload.id)
        LiveActivityController.end(id: payload.id)
        CloudSyncController.pushDelete(id: payload.id)
        WatchSyncController.pushCurrentState()
        timers.removeAll { $0.id == payload.id }
    }

    private func togglePause(_ payload: TimerPayload) {
        let updated = payload.isPaused ? payload.resumed() : payload.paused()
        applyMutation(updated, action: updated.isPaused ? "paused" : "resumed")
    }

    private func extend(_ payload: TimerPayload, by interval: TimeInterval) {
        applyMutation(payload.extended(by: interval), action: "extended")
    }

    /// Restart a finished timer/countdown in place (same id, original duration).
    private func repeatTimer(_ payload: TimerPayload) {
        alarm.stop()
        vibration.stop()
        armedIDs.remove(payload.id)
        applyMutation(payload.repeated(), action: "repeated")
    }

    /// Shared by the row's swipe/context-menu actions and TimerDetailView's own controls
    /// (both mutate a timer the same way). The mutation always applies immediately —
    /// gating it behind the name prompt risked the alert not presenting from a pushed
    /// TimerDetailView and silently dropping the pause/extend. The prompt runs alongside,
    /// not in front of it: if no name is set yet, this push writes "Someone"
    /// (DisplayNameStore's documented fallback) and the next one picks up whatever the
    /// person enters.
    private func applyMutation(_ updated: TimerPayload, action: String) {
        apply(updated, action: action)
        if CloudLinkStore.get(timerID: updated.id) != nil {
            promptForNameIfNeeded()
        }
    }

    /// Fire-and-forget version for call sites that don't need to wait on the result
    /// (mutations — see applyMutation). No-ops if a name is already set.
    private func promptForNameIfNeeded() {
        guard DisplayNameStore.name == nil else { return }
        showingNamePrompt = true
    }

    /// Runs `then` immediately if a display name is already set (DisplayNameStore); else
    /// prompts once and runs `then` after Continue/Skip. Only used for the Share… flow,
    /// where the prompt has to resolve before the share sheet opens (two presentations at
    /// once would fight each other) — see DisplayNameStore.swift for the skip fallback.
    private func withDisplayName(_ then: @escaping () -> Void) {
        guard DisplayNameStore.name == nil else {
            then()
            return
        }
        pendingNameCompletion = then
        showingNamePrompt = true
    }

    private func apply(_ updated: TimerPayload, action: String = "updated") {
        TimerStore.save(updated)
        armAlerts(for: updated)
        CloudSyncController.pushUp(updated, action: action)
        WatchSyncController.pushCurrentState()
        if let index = timers.firstIndex(where: { $0.id == updated.id }) {
            timers[index] = updated
        } else {
            timers.append(updated)
        }
    }

    /// Universal link / App Clip handoff into the full app. A timer already in the local
    /// store updates silently (matches the Messages extension); a genuinely new one surfaces
    /// the add-confirmation sheet instead of merging straight in.
    ///
    /// A `ckshare` query param means the sender's Messages extension successfully created
    /// a live-synced timer — accept it in the background and upgrade the stored copy to
    /// the authoritative cloud record once that resolves. This runs on EVERY open of the
    /// link, not just the first — re-tapping the same link (including the sender checking
    /// their own sent link) must still (re-)establish CloudLink, or later pause/resume/
    /// extend on this device silently has nothing to push to. Absence of the param (or a
    /// failed accept) leaves the plain-link snapshot exactly as it was — no regression.
    private func openQuickAction(_ type: String) {
        switch type {
        case "newTimer": pendingNewTimerKind = .timer
        case "newCountdown": pendingNewTimerKind = .countdown
        default: return
        }
        showingNewTimer = true
    }

    private func handleIncoming(url: URL?) {
        guard let parsed = TimerPayload.from(url: url) else { return }
        let alreadyKnown = timers.contains(where: { $0.id == parsed.id })
        if !alreadyKnown {
            incomingPayload = parsed
        }

        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shareString = components.queryItems?.first(where: { $0.name == "ckshare" })?.value,
              let shareURL = URL(string: shareString) else { return }

        CloudSyncController.acceptShare(from: shareURL) { authoritative in
            guard let authoritative else { return }
            DispatchQueue.main.async {
                if incomingPayload?.id == authoritative.id {
                    // Still showing the add-confirmation sheet for this timer — upgrade
                    // it to the authoritative cloud state before the user taps Add.
                    incomingPayload = authoritative
                } else if timers.contains(where: { $0.id == authoritative.id }) {
                    // Already added (e.g. re-tapping the link after accepting once, or
                    // the sender re-opening their own link) — refresh in place instead of
                    // resurfacing a sheet that's already been dismissed.
                    apply(authoritative)
                }
            }
        }
    }

    /// Applies remote changes pulled from CloudKit through the same local mutation
    /// sequence every other surface uses, then folds the results into the visible list.
    private func pullCloudChanges() {
        CloudSyncController.pullChanges { updated, deletedIDs in
            DispatchQueue.main.async {
                for payload in updated {
                    TimerStore.save(payload)
                    armAlerts(for: payload)
                    if let index = timers.firstIndex(where: { $0.id == payload.id }) {
                        timers[index] = payload
                    } else {
                        timers.append(payload)
                    }
                }
                for id in deletedIDs {
                    TimerStore.delete(id: id)
                    AlarmController.clear(id: id)
                    LiveActivityController.end(id: id)
                    timers.removeAll { $0.id == id }
                }
                // Unconditional, not gated on updated/deletedIDs being non-empty — this
                // is also where the scenePhase handler's TimerStore.loadAll() re-read
                // (Siri-intent/Messages-extension mutations made while backgrounded)
                // needs to reach the watch, and that path has no CloudKit delta at all.
                WatchSyncController.pushCurrentState()
            }
        }
    }
}

private struct NewTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var kind: TimerKind
    @State private var minutes: Double = 5
    @State private var targetDate: Date = Date().addingTimeInterval(86400)
    @State private var alarmEnabled = true
    @State private var vibrationEnabled = true
    @FocusState private var labelFocused: Bool

    let onCreate: (TimerPayload) -> Void

    init(initialKind: TimerKind = .timer, onCreate: @escaping (TimerPayload) -> Void) {
        self._kind = State(initialValue: initialKind)
        self.onCreate = onCreate
    }

    /// Live preview of the sky this timer will get.
    private var previewPayload: TimerPayload {
        TimerPayload.compose(label: label.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : label,
                             kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SkyCard(payload: previewPayload, date: Date())
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
                    kindLocked: true
                )
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
                    Button("Start") {
                        onCreate(TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// A starting point the sequence compose sheet seeds itself from — Pomodoro and
/// Intermittent Fasting are just worked examples of the underlying concept (phases
/// that run back-to-back, looping as a whole); "Custom" starts from a single blank
/// phase. Once picked, a template only supplies initial values — the user is free to
/// rename, add, remove, reorder, or edit every phase from there (see CLAUDE.md).
private struct SequenceTemplate: Equatable {
    /// The row label in "Start from" — always a real name, even for Custom.
    let name: String
    /// The name seeded into the "Sequence name" field — distinct from `name` only for
    /// Custom: an empty seed forces the user to actually name it (Start/Save are
    /// disabled on a blank name) instead of quietly saving/starting something titled
    /// "Custom".
    let seedName: String
    let blurb: String
    let phases: [SequencePhase]
    let defaultLoopCount: Int
}

private let sequenceTemplates: [SequenceTemplate] = [
    SequenceTemplate(
        name: "Custom",
        seedName: "",
        blurb: "Start from scratch and add whatever phases you like.",
        phases: [SequencePhase(label: "Phase 1", duration: 5 * 60)],
        defaultLoopCount: 1
    ),
    SequenceTemplate(
        name: "Pomodoro",
        seedName: "Pomodoro",
        blurb: "Work, then rest, on repeat.",
        phases: [
            SequencePhase(label: "Work", kind: .timer, duration: 25 * 60),
            SequencePhase(label: "Rest", kind: .timer, duration: 5 * 60)
        ],
        defaultLoopCount: 4
    ),
    SequenceTemplate(
        name: "Intermittent Fasting",
        seedName: "Intermittent Fasting",
        blurb: "Fast, then eat, day after day.",
        phases: [
            SequencePhase(label: "Fast", kind: .timer, duration: 16 * 3600),
            SequencePhase(label: "Eat", kind: .timer, duration: 8 * 3600)
        ],
        defaultLoopCount: 7
    )
]

/// Stable per-row identity for the phase list, independent of `SequencePhase` itself
/// (which carries no `id` — adding one would mean a Codable back-compat decode and a
/// 4-way cross-target diff for a value that's main-app-only in v1). `ForEach` keyed on
/// array index breaks the moment rows are insertable/deletable/reorderable: deleting a
/// middle phase would make SwiftUI reuse rows positionally, leaving stale text in
/// `TextField`s and jumping focus.
private struct DraftPhase: Identifiable {
    let id = UUID()
    var phase: SequencePhase
}

/// Which starting point currently seeded the draft — a built-in template (by index
/// into the fixed `sequenceTemplates` array) or one of the user's saved sequences (by
/// id). Needed instead of a bare `Int` the moment saved sequences join the list: that
/// list is mutable (deleting a saved sequence shifts every index after it), so an index
/// alone can't safely identify "which one is selected" across an edit.
private enum SequenceSource: Equatable {
    case builtin(index: Int)
    case saved(id: String)
}

/// The seed values a `SequenceSource` currently resolves to — same shape whether it
/// came from a built-in template or a saved sequence, so `isPristine`/`select` don't
/// need to know which.
private struct SequenceSeed: Equatable {
    let name: String
    let phases: [SequencePhase]
    let loopCount: Int
}

/// Compose sheet for a free-form sequence: start from a template or a saved sequence
/// (or from scratch), then add/remove/reorder/edit phases, set the loop count, and
/// optionally save the result for reuse.
private struct NewSequenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: SequenceSource = .builtin(index: 0)
    @State private var savedSequences: [SavedSequence] = SavedSequenceStore.loadAll()
    @State private var sequenceName: String
    @State private var draftPhases: [DraftPhase]
    @State private var loopCount: Int

    let onCreate: (TimerPayload) -> Void

    init(onCreate: @escaping (TimerPayload) -> Void) {
        self.onCreate = onCreate
        let first = sequenceTemplates[0]
        self._sequenceName = State(initialValue: first.seedName)
        self._draftPhases = State(initialValue: first.phases.map(DraftPhase.init))
        self._loopCount = State(initialValue: first.defaultLoopCount)
    }

    /// A sequence needs at least one phase (`composeSequence` preconditions on it) and
    /// a name — an editable list lets the user delete down to empty, so Start (and
    /// Save) must be gateable rather than crash.
    private var canCreate: Bool {
        !draftPhases.isEmpty && !sequenceName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func seed(for source: SequenceSource) -> SequenceSeed? {
        switch source {
        case .builtin(let index):
            guard sequenceTemplates.indices.contains(index) else { return nil }
            let template = sequenceTemplates[index]
            return SequenceSeed(name: template.seedName, phases: template.phases, loopCount: template.defaultLoopCount)
        case .saved(let id):
            guard let saved = savedSequences.first(where: { $0.id == id }) else { return nil }
            return SequenceSeed(name: saved.name, phases: saved.phases, loopCount: saved.loopCount)
        }
    }

    /// True as long as nothing has diverged from the given seed's values — used to
    /// decide whether switching "Start from" is still safe to apply. Once the user has
    /// touched the name, phases, or loop count, switching must leave the draft alone
    /// instead of silently discarding their edits.
    private func isPristine(against seed: SequenceSeed) -> Bool {
        sequenceName == seed.name && loopCount == seed.loopCount && draftPhases.map(\.phase) == seed.phases
    }

    private func select(_ newSource: SequenceSource) {
        guard newSource != source else { return }
        let wasPristine = seed(for: source).map(isPristine(against:)) ?? false
        source = newSource
        guard wasPristine, let newSeed = seed(for: newSource) else { return }
        sequenceName = newSeed.name
        draftPhases = newSeed.phases.map(DraftPhase.init)
        loopCount = newSeed.loopCount
    }

    /// Phases with any blank label defaulted, the same way "Add Phase" names a new one
    /// — shared by Start and Save so neither construction path can skip it.
    private func normalizedPhases() -> [SequencePhase] {
        draftPhases.enumerated().map { index, draft in
            var phase = draft.phase
            if phase.label.trimmingCharacters(in: .whitespaces).isEmpty {
                phase.label = "Phase \(index + 1)"
            }
            return phase
        }
    }

    /// Overwrites the saved sequence currently selected, or creates a new one — never
    /// both, so tapping Save repeatedly on the same draft updates one entry instead of
    /// piling up duplicates.
    private func saveSequence() {
        let name = sequenceName.trimmingCharacters(in: .whitespaces)
        let phases = normalizedPhases()
        if case .saved(let id) = source, let index = savedSequences.firstIndex(where: { $0.id == id }) {
            savedSequences[index] = SavedSequence(id: id, name: name, phases: phases, loopCount: loopCount)
        } else {
            let new = SavedSequence(name: name, phases: phases, loopCount: loopCount)
            savedSequences.append(new)
            source = .saved(id: new.id)
        }
        SavedSequenceStore.saveAll(savedSequences)
        // Match what was actually saved (trimmed name, defaulted phase labels) — otherwise
        // `isPristine` compares the un-normalized draft against the normalized seed and
        // reads as diverged even right after a save, silently blocking the next reseed.
        sequenceName = name
        draftPhases = phases.map(DraftPhase.init)
    }

    private func deleteSaved(at offsets: IndexSet) {
        let removedIDs = offsets.map { savedSequences[$0].id }
        savedSequences.remove(atOffsets: offsets)
        SavedSequenceStore.saveAll(savedSequences)
        if case .saved(let id) = source, removedIDs.contains(id) {
            select(.builtin(index: 0))
        }
    }

    @ViewBuilder
    private func startFromRow(name: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(sequenceTemplates.indices, id: \.self) { index in
                        startFromRow(
                            name: sequenceTemplates[index].name,
                            subtitle: sequenceTemplates[index].blurb,
                            isSelected: source == .builtin(index: index)
                        ) {
                            select(.builtin(index: index))
                        }
                    }
                    if !savedSequences.isEmpty {
                        ForEach(savedSequences) { saved in
                            startFromRow(
                                name: saved.name,
                                subtitle: "\(saved.phases.count) phase\(saved.phases.count == 1 ? "" : "s") · \(saved.loopCount)×",
                                isSelected: source == .saved(id: saved.id)
                            ) {
                                select(.saved(id: saved.id))
                            }
                        }
                        .onDelete(perform: deleteSaved)
                    }
                } header: {
                    Text("Start from")
                } footer: {
                    Text("A sequence runs each phase below back-to-back, then loops the whole thing.")
                }

                Section {
                    TextField("Sequence name", text: $sequenceName)
                }

                Section {
                    ForEach($draftPhases) { $draft in
                        NavigationLink {
                            PhaseEditView(phase: $draft.phase)
                        } label: {
                            HStack {
                                Image(systemName: draft.phase.kind == .timer ? "timer" : "calendar")
                                    .foregroundStyle(draft.phase.kind.accentColor)
                                VStack(alignment: .leading) {
                                    Text(draft.phase.label.isEmpty ? "Untitled phase" : draft.phase.label)
                                    Text(TimeFormat.daysHours(draft.phase.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { draftPhases.remove(atOffsets: $0) }
                    .onMove { draftPhases.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Phases")
                } footer: {
                    if draftPhases.isEmpty {
                        Text("Add at least one phase to start this sequence.")
                    }
                }

                Section {
                    Button {
                        draftPhases.append(DraftPhase(phase: SequencePhase(label: "Phase \(draftPhases.count + 1)", duration: 5 * 60)))
                    } label: {
                        Label("Add Phase", systemImage: "plus.circle")
                    }
                }

                Section {
                    Stepper("Repeat \(loopCount) time\(loopCount == 1 ? "" : "s")", value: $loopCount, in: 1...99)
                } footer: {
                    Text("Runs \(draftPhases.count) phase\(draftPhases.count == 1 ? "" : "s") per loop, \(loopCount) time\(loopCount == 1 ? "" : "s") total.")
                }

                Section {
                    Button {
                        saveSequence()
                    } label: {
                        if case .saved = source {
                            Label("Update Saved Sequence", systemImage: "square.and.arrow.down")
                        } else {
                            Label("Save as New Sequence", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(!canCreate)
                } footer: {
                    Text("Save this sequence to select and start it again later without rebuilding it.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle("New Sequence")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onCreate(TimerPayload.composeSequence(
                            label: sequenceName.trimmingCharacters(in: .whitespaces),
                            phases: normalizedPhases(),
                            loopCount: loopCount
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCreate)
                }
            }
        }
    }
}

/// Hours/minutes wheel for a single phase's duration — the same compact-wheel pattern
/// `TimerFieldsView` uses for a plain timer, sized for phases from a few minutes
/// (Pomodoro) to many hours (Intermittent Fasting). Floors at 1 minute: a zero-duration
/// phase would make `advancedSequence` blow straight through it on every tick.
private struct PhaseDurationPicker: View {
    @Binding var duration: TimeInterval

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { Int(duration) / 3600 },
            set: { newHours in
                let minutes = (Int(duration) % 3600) / 60
                duration = max(60, TimeInterval(newHours * 3600 + minutes * 60))
            }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { (Int(duration) % 3600) / 60 },
            set: { newMinutes in
                let hours = Int(duration) / 3600
                duration = max(60, TimeInterval(hours * 3600 + newMinutes * 60))
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hoursBinding) {
                ForEach(0..<24) { h in Text("\(h) hr").tag(h) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)

            Picker("Minutes", selection: minutesBinding) {
                ForEach(0..<60) { m in Text("\(m) min").tag(m) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 120)
    }
}

/// Drill-in editor for one phase of a sequence: label, duration, cosmetic look
/// (`SequencePhase.kind` is icon/tint only — never date-anchored, since a phase
/// re-runs on every loop, see `TimerModel.swift`), and its own alarm/vibrate toggles.
private struct PhaseEditView: View {
    @Binding var phase: SequencePhase

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $phase.label)

                Picker("Look", selection: $phase.kind) {
                    Text("Timer").tag(TimerKind.timer)
                    Text("Countdown").tag(TimerKind.countdown)
                }
                .pickerStyle(.segmented)
            }

            Section {
                PhaseDurationPicker(duration: $phase.duration)
            } footer: {
                Text("How long this phase runs each time it comes up.")
            }

            Section {
                Toggle("Alarm", isOn: $phase.alarmEnabled)
                    .tint(phase.kind.accentColor)
                Toggle("Vibrate", isOn: $phase.vibrationEnabled)
                    .tint(phase.kind.accentColor)
            } header: {
                Text("When this phase ends")
            } footer: {
                Text(phase.alarmEnabled || phase.vibrationEnabled
                     ? "Rings or buzzes full-screen with Stop and Repeat, even when the app is closed or the phone is on silent."
                     : "A quiet notification instead — no ringing.")
            }
        }
        .navigationTitle(phase.label.isEmpty ? "Phase" : phase.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tap-through detail: the timer's sky, full-bleed and slowly swaying, with the time
/// glowing in the middle and frosted controls floating at the bottom.
private struct TimerDetailView: View {
    @State private var payload: TimerPayload
    let onUpdate: (TimerPayload, String) -> Void
    let onDelete: (TimerPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var participantCount: Int?
    @State private var attribution: (name: String, action: String)?
    @State private var hasBuzzedFinish = false
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

    init(payload: TimerPayload, onUpdate: @escaping (TimerPayload, String) -> Void, onDelete: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired
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

                VStack {
                    Spacer()

                    VStack(spacing: 10) {
                        Text(payload.label)
                            .skyLabel(13)
                            .foregroundStyle(.white.opacity(0.85))
                        if let caption = payload.sequenceCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Text(TimeFormat.display(remaining))
                            .skyDigits(72, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 24)
                        Text(subtitle(done: done))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                        if let statusLine {
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    Spacer()

                    if !done {
                        HStack(spacing: 12) {
                            Button("+1:00") {
                                extend(by: 60)
                            }
                            .buttonStyle(.glassPill)

                            Button(payload.isPaused ? "Resume" : "Pause") {
                                togglePause()
                            }
                            .buttonStyle(.glassPill)
                        }
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
                        }
                    }

                    Button {
                        onDelete(payload)
                        dismiss()
                    } label: {
                        Text("Delete")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 28)
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
                // does — nothing else refreshes it on a plain tick. Same skip as there
                // while AlarmKit owns the alert (see AlarmController.alarmKitOwnsAlert):
                // `onUpdate` -> ... -> `reschedule` would cancel AlarmKit's own
                // just-fired alert out from under the user before they can act on it.
                if payload.sequence != nil && !AlarmController.alarmKitOwnsAlert(for: payload) {
                    let advanced = payload.advancedSequence()
                    payload = advanced
                    onUpdate(advanced, "sequenceAdvanced")
                    // Not exhausted -> a new phase just started and can finish again
                    // later; let it re-buzz on that future zero-crossing.
                    hasBuzzedFinish = advanced.isExpired
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // Sequences aren't shareable in v1 — see the row context-menu's identical gate.
            if payload.sequence == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: payload.url()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            hasBuzzedFinish = payload.isExpired
            CloudSyncController.fetchParticipantCount(for: payload) { participantCount = $0 }
            CloudSyncController.fetchAttribution(for: payload) { attribution = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .externalTimerStoreChange)) { _ in
            // This view holds its own @State copy of payload (seeded once when pushed),
            // so a watch-relayed pause or CloudKit push landing while this exact screen is
            // open would otherwise sit invisible until the user backs out and re-enters —
            // ContentView's own reload (TimerStore.loadAll() into its `timers` array)
            // doesn't touch this already-pushed view's local copy at all.
            guard let fresh = TimerStore.loadAll().first(where: { $0.id == payload.id }) else { return }
            payload = fresh
        }
    }

    private func subtitle(done: Bool) -> String {
        if done {
            return "Finished \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        }
        if payload.isPaused {
            return "Paused"
        }
        if payload.kind == .countdown {
            return TimeFormat.targetDate(payload.endDate)
        }
        return "ends at \(payload.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private func togglePause() {
        payload = payload.isPaused ? payload.resumed() : payload.paused()
        onUpdate(payload, payload.isPaused ? "paused" : "resumed")
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload, "extended")
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
            parts.append("\(participantCount) watching")
        }
        if let attribution, attribution.name != DisplayNameStore.name {
            parts.append("\(attribution.name) \(attribution.action)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Sheet shown from a row's context-menu Share action. `ShareLink` inside `.contextMenu`
/// is unreliable, so this presents the timer's sky with the real `ShareLink` on it.
private struct ShareTimerSheet: View {
    let payload: TimerPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                SkyCard(payload: payload, date: Date())
                    .padding(.horizontal, 20)

                ShareLink(item: payload.url()) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .padding(.horizontal, 20)

                Spacer()
            }
            .padding(.top, 26)
            .background(Sky.room)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Confirmation sheet for a timer arriving via universal link while the full app is
/// already installed — its sky, then what it is, then the choice.
private struct AddSharedTimerSheet: View {
    let payload: TimerPayload
    let onAdd: (TimerPayload) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                SkyCard(payload: payload, date: Date())
                    .padding(.horizontal, 20)

                VStack(spacing: 6) {
                    Text("Shared timer from a link")
                        .font(.subheadline)
                        .foregroundStyle(Sky.roomInk)
                    if payload.kind == .timer {
                        Text("Ends at \(payload.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(Sky.roomInk)
                    } else {
                        Text("Counting down to \(TimeFormat.targetDate(payload.endDate))")
                            .font(.footnote)
                            .foregroundStyle(Sky.roomInk)
                    }
                }

                Spacer()

                Button {
                    onAdd(payload)
                } label: {
                    Text("Add to My Timers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .padding(.horizontal, 20)

                Button("Not Now") {
                    onDismiss()
                }
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
                .padding(.bottom, 16)
            }
            .padding(.top, 26)
            .background(Sky.room)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ContentView()
}
