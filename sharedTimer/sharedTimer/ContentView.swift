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
    /// Same self-initializing pattern as `armedIDs`: starts empty, so the first tick
    /// after launch only records "already pending," never spuriously treats a payload
    /// that was pending before the app ever opened as "just started."
    @State private var pendingIDs: Set<String> = []
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
                            // rather than sitting in Active forever. Pending gets its own
                            // section (it hasn't started, semantically not "Active" yet)
                            // sorted by start date, soonest first.
                            let pending = timers.filter { $0.isPending(at: context.date) }
                                .sorted { ($0.scheduledStartDate ?? .distantFuture) < ($1.scheduledStartDate ?? .distantFuture) }
                            let active = timers.filter { !$0.isFinished && !$0.isPending(at: context.date) }.sorted { $0.endDate < $1.endDate }
                            let expired = timers.filter { $0.isFinished }.sorted { $0.endDate > $1.endDate }

                            if !active.isEmpty {
                                Section {
                                    ForEach(active) { row(for: $0, at: context.date) }
                                } header: {
                                    Text("Active").skyLabel().foregroundStyle(Sky.roomInk)
                                }
                            }
                            if !pending.isEmpty {
                                Section {
                                    ForEach(pending) { row(for: $0, at: context.date) }
                                } header: {
                                    Text("Scheduled").skyLabel().foregroundStyle(Sky.roomInk)
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
        // A pending payload's real alert is already armed from creation regardless --
        // AlarmKit's own `schedule: .fixed(endDate)` transitions scheduled->countdown
        // on its own at the real start time (see AlarmController.scheduleAlarm), and a
        // both-toggles-off payload's NotificationScheduler alert was already set for
        // `endDate` too. Calling the full `armAlerts` here would cancel-then-reschedule
        // the AlarmKit alarm at exactly the moment it's transitioning on its own --
        // the exact cancel-out-from-under-the-user race CLAUDE.md already warns about
        // elsewhere (see `alarmKitOwnsAlert`). Only the custom Live Activity (the
        // both-toggles-off case only) actually needs a nudge here: it's deliberately
        // withheld while pending, and without this it would only appear on the next
        // background/foreground cycle.
        let justStarted = timers.filter { pendingIDs.contains($0.id) && !$0.isPending(at: date) }
        pendingIDs = Set(timers.filter { $0.isPending(at: date) }.map(\.id))
        for payload in justStarted where !AlarmController.ownsAlert(for: payload) {
            LiveActivityController.start(for: payload)
        }

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
            } else if payload.isPending() {
                // Pause/Extend don't mean anything before a scheduled start actually
                // begins -- Delete (already the trailing swipe action) doubles as
                // "Cancel", and this lets someone not wait for the pick they made.
                Button {
                    startEarly(payload)
                } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
                .tint(.teal)
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
            } else if payload.isPending() {
                Button {
                    startEarly(payload)
                } label: {
                    Label("Start Now", systemImage: "play.fill")
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
        TimerArming.arm(payload)
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

    /// "Start Now" on a pending sequence -- reuses `repeated(at:)` rather than adding a
    /// new model function: a pending sequence is already sitting at phase 0/loop 0
    /// (never advanced or stepped), so "reset to phase 0/loop 0, endDate = now +
    /// phase0.duration, clear scheduledStartDate" is exactly "start now," with no
    /// sequence-specific logic beyond what `repeated()` already does. Not `repeatTimer`
    /// (above) -- this was never alerting, so there's no alarm/vibration to stop and no
    /// `armedIDs` entry to clear.
    private func startEarly(_ payload: TimerPayload) {
        applyMutation(payload.repeated(), action: "startedEarly")
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

    private func openQuickAction(_ type: String) {
        switch type {
        case "newTimer": pendingNewTimerKind = .timer
        case "newCountdown": pendingNewTimerKind = .countdown
        default: return
        }
        showingNewTimer = true
    }

    /// Universal link / App Clip handoff into the full app. A timer already in the local
    /// store is left as-is (the link's snapshot may be older than what's stored — the link
    /// carries no recency marker; same in the Messages extension); a genuinely new one
    /// surfaces the add-confirmation sheet instead of merging straight in.
    ///
    /// A `ckshare` query param means the sender's Messages extension successfully created
    /// a live-synced timer — accept it in the background and upgrade the stored copy to
    /// the authoritative cloud record once that resolves. This runs on EVERY open of the
    /// link, not just the first — re-tapping the same link (including the sender checking
    /// their own sent link) must still (re-)establish CloudLink, or later pause/resume/
    /// extend on this device silently has nothing to push to. Absence of the param (or a
    /// failed accept) leaves the plain-link snapshot exactly as it was — no regression.
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
