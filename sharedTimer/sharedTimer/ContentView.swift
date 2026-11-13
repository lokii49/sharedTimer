//
//  ContentView.swift
//  sharedTimer
//

import AppIntents
import CoreSpotlight
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var navigationPath: [String] = []
    @State private var timers: [TimerPayload] = TimerStore.loadAll()
    @State private var showingNewSequence = false
    @State private var showingHistory = false
    @State private var pendingNewTimerKind: TimerKind?
    @State private var sharingPayload: TimerPayload?
    @State private var editingPayload: TimerPayload?
    /// The row whose context-menu "Custom…" add-time picker is open.
    @State private var customExtendPayload: TimerPayload?
    /// The share being managed from a row's context menu (UICloudSharingController).
    @State private var managedShare: (item: CloudShareItem, timerID: String)?
    /// A shared timer this device owns, waiting for "Delete for Everyone" to be confirmed.
    @State private var deleteForEveryonePayload: TimerPayload?
    @State private var showingWhatsNew = false
    @State private var showingSettings = false
    /// Set by any deep link (URL, Spotlight, Quick Action) this launch: the person came
    /// for something specific, so the What's New tour stays out of the way.
    @State private var deepLinkArrived = false
    @State private var incomingPayload: TimerPayload?
    /// Live shares the person dismissed without adding. `acceptShare` runs before they
    /// decide (so the sheet shows the authoritative state), which joins the share zone —
    /// without leaving again, the declined timer appeared on the next pull anyway.
    @State private var declinedShareIDs: Set<String> = []
    @State private var lastOfferedShareID: String?
    /// The last removed timer, for the Undo toast (local timers and ones shared with
    /// this phone; "Delete for Everyone" has its own confirmation instead).
    @State private var undoableDeletion: TimerPayload?
    @State private var undoTask: Task<Void, Never>?
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

    // No list-wide TimelineView: it re-filtered, re-sorted and rebuilt every row
    // (swipe/context menus included — their closures aren't lazy) every second.
    // Each card ticks on its own (`LiveSkyCard`); the list re-evaluates only when
    // `timers`, `armedIDs` or `pendingIDs` change — a finish or a scheduled start.
    private var timerList: some View {
        let now = Date()
        return Group {
                if timers.isEmpty {
                    emptyState
                } else {
                    List {
                        // isFinished, not isExpired: a timer paused exactly at zero is
                        // still "paused" for alarm purposes, but reads as Finished here
                        // rather than sitting in Active forever. Pending gets its own
                        // section (it hasn't started, semantically not "Active" yet)
                        // sorted by start date, soonest first.
                        let pending = timers.filter { $0.isPending(at: now) }
                            .sorted { ($0.scheduledStartDate ?? .distantFuture) < ($1.scheduledStartDate ?? .distantFuture) }
                        let active = timers.filter { !$0.isFinished && !$0.isPending(at: now) }.sorted { $0.endDate < $1.endDate }
                        let expired = timers.filter { $0.isFinished }.sorted { $0.endDate > $1.endDate }

                        if !active.isEmpty {
                            Section {
                                ForEach(active) { row(for: $0) }
                            } header: {
                                Text("Active").skyLabel().foregroundStyle(Sky.roomInk)
                            }
                        }
                        if !pending.isEmpty {
                            Section {
                                ForEach(pending) { row(for: $0) }
                            } header: {
                                Text("Scheduled").skyLabel().foregroundStyle(Sky.roomInk)
                            }
                        }
                        if !expired.isEmpty {
                            Section {
                                ForEach(expired) { row(for: $0) }
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
            // The 1s expiry tick, on its own: it must keep running with an empty list
            // and see every zero-crossing and scheduled start (TimelineView localizes
            // invalidation to its closure, so only this clear view re-evaluates).
            .background {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Color.clear.onChange(of: context.date) { _, date in
                        checkForNewlyExpired(at: date)
                    }
                }
            }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPad in a regular-width window. Not size class alone: a Pro Max iPhone in
    /// landscape is regular width too, and keeps the iPhone layout.
    private var isRegular: Bool { UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular }

    /// The detail column on iPad: the selected timer, or a prompt to pick one.
    @ViewBuilder private var splitDetail: some View {
        if let timerID = navigationPath.last {
            detailDestination(timerID)
                // A fresh detail for each pick — it keeps its own @State copy.
                .id(timerID)
        } else {
            ContentUnavailableView("Choose a timer", systemImage: "timer", description: Text("Pick a timer on the left, or start a new one with +."))
        }
    }

    @ViewBuilder private func detailDestination(_ timerID: String) -> some View {
        if let payload = timers.first(where: { $0.id == timerID }) {
            TimerDetailView(payload: payload, onUpdate: applyMutation, onSequenceAdvance: { apply($0, action: "sequenceAdvanced", rearm: $1) }, onDelete: delete, onShare: { payload in withDisplayName { sharingPayload = payload } })
        } else {
            ContentUnavailableView("Timer unavailable", systemImage: "timer", description: Text("This timer has been deleted or has expired."))
        }
    }

    /// The list column with its title, toolbar and everything presented from it —
    /// the whole screen on iPhone, the sidebar on iPad.
    private var columnContent: some View {
            timerList
            .navigationDestination(for: String.self) { timerID in
                detailDestination(timerID)
            }
            .navigationTitle("Timers")
            .toolbar {
                // D9 · A: History on the leading side, so the trailing side keeps
                // just Settings and +.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("History")
                    .accessibilityIdentifier("historyButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pendingNewTimerKind = .timer
                        } label: {
                            Label("New Timer", systemImage: "timer")
                        }
                        Button {
                            pendingNewTimerKind = .countdown
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
                            .accessibilityLabel("New")
                    }
                }
            }
            .sheet(item: $pendingNewTimerKind) { kind in
                NewTimerSheet(initialKind: kind) { payload in
                    startNew(payload)
                }
            }
            .sheet(item: $editingPayload) { payload in
                EditTimerSheet(payload: payload) { edited in
                    applyEdit(edited)
                }
            }
            .confirmationDialog(String(localized: "Delete for everyone?"),
                                isPresented: Binding(get: { deleteForEveryonePayload != nil }, set: { if !$0 { deleteForEveryonePayload = nil } }),
                                titleVisibility: .visible, presenting: deleteForEveryonePayload) { payload in
                Button(String(localized: "Delete for Everyone"), role: .destructive) { delete(payload) }
            } message: { _ in
                Text("It stops for everyone you shared it with.")
            }
            .sheet(isPresented: Binding(get: { managedShare != nil }, set: { if !$0 { managedShare = nil } }), onDismiss: {
                CloudSyncController.refreshPermissions { timers = TimerStore.loadAll() }
            }) {
                if let managedShare {
                    CloudSharingView(item: managedShare.item, title: timers.first { $0.id == managedShare.timerID }?.label ?? "") {
                        CloudSyncController.didStopSharing(timerID: managedShare.timerID)
                        timers = TimerStore.loadAll()
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(item: $customExtendPayload) { payload in
                CustomExtendSheet { interval in
                    // The newest copy: the row's may be seconds old by now.
                    if let current = timers.first(where: { $0.id == payload.id }), !current.isFinished { extend(current, by: interval) }
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
                afterWhatsNewYields { openQuickAction(type) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .spotlightTimerOpened)) { notification in
                if let identifier = notification.object as? String { afterWhatsNewYields { openSpotlightTimer(identifier) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .externalTimerStoreChange)) { _ in
                // Watch-relayed mutation or CloudKit silent push landed while this view
                // is already foregrounded — scenePhase alone won't fire here since we
                // never left .active. Re-read TimerStore directly.
                let fresh = TimerStore.loadAll()
                // A remote delete (silent push) of a timer ringing in-app must silence it,
                // as pullCloudChanges does. Before the reassign: it reads `timers`.
                let freshIDs = Set(fresh.map(\.id))
                for payload in timers where !freshIDs.contains(payload.id) {
                    stopInAppAlertIfRinging(for: payload.id)
                }
                // A remote Repeat/Extend/Resume of a timer ringing in-app moved its
                // finish: the loop and banner are for a finish that no longer exists.
                for payload in fresh where !payload.isFinished {
                    stopInAppAlertIfRinging(for: payload.id)
                }
                timers = fresh
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.permissionsChanged)) { notification in
                // Re-render so the menus' enabled state follows the new permission, and
                // re-arm just the timers whose permission changed: their full-screen
                // alert's second button depends on it (Open when view only).
                rearmAfterSharingChange(ids: notification.object as? [String] ?? [])
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.sharingChanged)) { notification in
                // Shared or unshared (Stop Sharing / Remove Me): a timer that left a
                // view-only share needs its normal alert buttons back.
                rearmAfterSharingChange(ids: (notification.object as? String).map { [$0] } ?? [])
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudSyncController.revertedToServer)) { notification in
                // CloudKit refused a change (the share became view-only): the store
                // already holds the server's copy — show it and re-arm to it.
                timers = TimerStore.loadAll()
                if let payload = notification.object as? TimerPayload { armAlerts(for: payload) }
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
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
            .sheet(isPresented: $showingHistory) {
                TimerHistoryView(onRunAgain: { startNew($0) }, onOpen: { openTimerDetails($0) })
            }
            .sheet(item: $incomingPayload, onDismiss: leaveDeclinedShares) { payload in
                AddSharedTimerSheet(
                    payload: payload,
                    onAdd: { accepted in
                        apply(accepted.advancedSequence())
                        incomingPayload = nil
                    },
                    onDismiss: { incomingPayload = nil }
                )
            }
    }

    var body: some View {
        Group {
            if isRegular {
                // D10 · A (iPad): the list as a sidebar, the selected timer's sky on the
                // right. Selection is `navigationPath.last`, so every deep link that sets
                // the path (Spotlight, widget URL, Quick Action, History's Open) selects.
                NavigationSplitView {
                    columnContent
                } detail: {
                    NavigationStack { splitDetail }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $navigationPath) {
                    columnContent
                }
            }
        }
        // Outside the NavigationStack: attached to the list root, this prompt and sheet
        // never appeared while TimerDetailView was pushed, so its Share button did nothing
        // for anyone without a stored display name.
        .sheet(item: $sharingPayload) { payload in
            ShareTimerSheet(payload: payload)
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
                DisplayNameStore.declined = true
                pendingNameCompletion?()
                pendingNameCompletion = nil
            }
        } message: {
            Text("Shown to people you share timers with, like \"Sam paused Pasta.\" You can change it any time in Settings.")
        }
        .tint(.white)
        .overlay(alignment: .bottom) {
            if alarm.isPlaying || vibration.isVibrating {
                alarmBanner
            } else if let deleted = undoableDeletion {
                undoToast(for: deleted)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: undoableDeletion?.id)
        .sensoryFeedback(.impact(weight: .light), trigger: timers.count)
        .onChange(of: TimerChoiceQuery.choices(from: timers)) { _, _ in
            TimerShortcuts.updateAppShortcutParameters()
            TimerSpotlightIndex.shared.requestRefresh()
        }
        .onAppear {
            TimerShortcuts.updateAppShortcutParameters()
            TimerSpotlightIndex.shared.requestRefresh()
            timers = TimerStore.loadAll()
            // Re-derive every sequence's current phase from scratch before anything
            // else touches `timers` — correct no matter how long the app was closed
            // (even having missed several whole phases), and must run before
            // reconcileRepeat so a legitimately mid-sequence payload never reaches it
            // still reading as merely "finished" (see AlarmController.reconcileRepeat).
            for index in timers.indices where timers[index].sequence != nil || timers[index].recurrence != nil {
                let advanced = timers[index].advancedSequence()
                if advanced.endDate != timers[index].endDate || advanced.sequence?.phaseIndex != timers[index].sequence?.phaseIndex {
                    timers[index] = advanced
                    TimerStore.save(advanced)
                }
            }
            // Fold any "Repeat" tapped on a fired timer's AlarmKit panel back in before
            // arming — the arm loop below then re-aligns the alarm to the revived endDate.
            for id in AlarmController.reconcileRepeat(into: &timers) {
                if let revived = timers.first(where: { $0.id == id }) {
                    TimerStore.save(revived)
                    // Other participants of a shared timer never saw this Repeat before.
                    CloudSyncController.pushUp(revived, action: "repeated")
                }
            }
            // Finished sequences too: one cancelled elsewhere (Messages, the notification
            // service) still has pre-armed phase alarms; re-arming a finished sequence only
            // cancels those, never an occurrence that is ringing.
            for payload in timers where !payload.isExpired || payload.sequence != nil {
                armAlerts(for: payload)
            }
            // After arming: cancels AlarmKit alarms no stored timer explains (e.g. a paused
            // one left by a timer deleted in Messages, which can't reach AlarmKit).
            AlarmController.sweepStrayAlarms()
            LiveActivityController.endFinished(timers.filter { !AlarmController.ownsAlert(for: $0) })
            SharePlayController.shared.onReceive = { receiveFromSharePlay($0) }
            RecentTimersStore.seedIfNeeded(from: timers)
            RecentTimersSync.refresh()
            pullCloudChanges()
            if SceneDelegate.pendingSpotlightIdentifier != nil || SceneDelegate.pendingShortcutType != nil {
                deepLinkArrived = true
            }
            presentWhatsNewIfNeeded()
            if let identifier = SceneDelegate.pendingSpotlightIdentifier {
                SceneDelegate.pendingSpotlightIdentifier = nil
                openSpotlightTimer(identifier)
            }
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
                // The Undo window ends when the app leaves the screen.
                finishUndoableDeletion()
                // No background-audio entitlement — the AVAudioPlayer loop would be cut
                // off by the OS anyway; stop it explicitly so isPlaying/the banner don't
                // linger in a stale "still ringing" state. The scheduled notification's
                // own alarm.caf sound covers the backgrounded case. `.inactive` (a
                // Control Center pull, app-switcher peek) is deliberately excluded here —
                // that's a transient gesture, not a real backgrounding, and shouldn't
                // silently kill a ringing alarm.
                alarm.stop()
                vibration.stop()
                BackgroundRefresh.schedule()
            }
            guard newPhase == .active else { return }
            TimerSpotlightIndex.shared.requestRefresh()
            // Re-read TimerStore first — a timer created while backgrounded (e.g. via
            // TimerIntents.swift's Siri intents) writes straight to the App Group and has
            // no CloudLink, so pullCloudChanges alone would never surface it here.
            let beforeBackground = Dictionary(timers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            timers = TimerStore.loadAll()
            // Same sequence re-derivation as onAppear, and for the same reason: must
            // run before reconcileRepeat, since a mid-sequence payload sitting
            // un-advanced also reads as `isFinished`.
            for index in timers.indices where timers[index].sequence != nil || timers[index].recurrence != nil {
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
                        CloudSyncController.pushUp(revived, action: "repeated")
                    }
                }
                WatchSyncController.pushCurrentState()
            }
            for payload in timers where payload.recurrence != nil { armAlerts(for: payload) }
            // A change made while backgrounded by something that can't move AlarmKit (an
            // extend/pause in Messages, a timer composed there) left AlarmKit at its old
            // time or unarmed. Re-arm only new or changed payloads that aren't finished — re-arming an unchanged or
            // ringing one would cancel the alert the person is opening the app from.
            for payload in timers where payload.recurrence == nil && payload.sequence == nil && !payload.isExpired {
                if let old = beforeBackground[payload.id], Self.alertShape(old) == Self.alertShape(payload) { continue }
                armAlerts(for: payload)
            }
            // Same for a sequence paused, extended or cancelled in Messages (or saved by the
            // notification service): its pre-armed phase alarms kept the old times. Compared
            // at the same projection; finished ones too, so a cancel tears the window down
            // (the sequence path never cancels an occurrence that is ringing).
            for payload in timers where payload.recurrence == nil && payload.sequence != nil {
                if let old = beforeBackground[payload.id], Self.alertShape(old.advancedSequence()) == Self.alertShape(payload) { continue }
                armAlerts(for: payload)
            }
            // An open TimerDetailView holds its own copy; without this it kept showing
            // (and on Pause/+1:00, saving and pushing) the pre-background state.
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
            // Runs that ended while the app was away (TimerHistory.swift).
            TimerHistory.scan()
            // A timer deleted in Messages while the app was away leaves its alarm behind.
            AlarmController.sweepStrayAlarms()
            pullCloudChanges()
            // The owner can switch a share to view only at any time; re-read so the
            // controls match before anyone taps one.
            CloudSyncController.refreshPermissions {
                timers = TimerStore.loadAll()
                NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
            }
            // Opportunistic Live Activity keep-alive: there's no server here to push a
            // periodic refresh while the app isn't running, so a multi-day countdown's
            // activity only survives past iOS's ~8h no-update budget if something re-pushes
            // it — foregrounding the app is the cheapest reliable trigger available.
            // The custom Live Activity only runs where AlarmKit doesn't own one —
            // both toggles off, for either kind (see armAlerts).
            LiveActivityController.refreshAll(from: timers.filter { !AlarmController.ownsAlert(for: $0) })
            LiveActivityController.endFinished(timers.filter { !AlarmController.ownsAlert(for: $0) })
        }
        .onOpenURL { url in
            afterWhatsNewYields {
                if let timerID = TimerAppLink.timerID(from: url) {
                    openTimerDetails(timerID)
                } else {
                    handleIncoming(url: url)
                }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                afterWhatsNewYields { openSpotlightTimer(identifier) }
            }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            afterWhatsNewYields { handleIncoming(url: activity.webpageURL) }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showingWhatsNew) {
            WhatsNewView { showingWhatsNew = false }
        }
    }

    /// A deep link beats the What's New tour: suppress it if it hasn't appeared yet, or
    /// dismiss it first — presenting a sheet while the cover is still up (or on its way
    /// down) silently drops the sheet.
    private func afterWhatsNewYields(_ action: @escaping () -> Void) {
        deepLinkArrived = true
        guard showingWhatsNew else { return action() }
        showingWhatsNew = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: action)
    }

    /// Cold launch only (onAppear). Waits a beat so a link delivered right after
    /// launch can claim the screen first; the version is marked seen either way.
    private func presentWhatsNewIfNeeded() {
        guard WhatsNew.consumeLaunchPresentation() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !deepLinkArrived { showingWhatsNew = true }
        }
    }

    private func openSpotlightTimer(_ identifier: String) {
        guard let timerID = TimerSpotlightIndex.timerID(from: identifier) else { return }
        openTimerDetails(timerID)
    }

    private func openTimerDetails(_ timerID: String) {
        timers = TimerStore.loadAll()
        // Show the unavailable destination for a stale deleted result; never import
        // or recreate a timer from search metadata.
        navigationPath = [timerID]
        TimerSpotlightIndex.shared.requestRefresh()
    }

    /// The empty room holds one deep-night sky, waiting.
    /// C7 · A (1.0.7 mockup): one tile per kind, each opening its existing sheet, plus
    /// one-tap starts — Recent timers, or a few presets on a fresh install.
    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start something")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)
                EmptyStateTile(title: "Timer", detail: "Minutes and seconds. Rings when it ends.", sample: "08:00",
                               colors: Sky.ember.stops(drain: 0.2)) { pendingNewTimerKind = .timer }
                EmptyStateTile(title: "Countdown", detail: "To a date. Birthdays, trips, launches.", sample: "12d",
                               colors: Sky.night.stops(drain: 0.2)) { pendingNewTimerKind = .countdown }
                EmptyStateTile(title: "Sequence", detail: "Phases on a loop. Pomodoro, fasting.", sample: "25 · 5",
                               colors: Sky.dusk.stops(drain: 0.2)) { showingNewSequence = true }

                let recents = RecentTimersStore.all()
                Text(recents.isEmpty ? "Quick start" : "Recent")
                    .skyLabel(11)
                    .foregroundStyle(Sky.roomInk)
                    .padding(.top, 10)
                ChipFlowLayout(spacing: 8) {
                    if recents.isEmpty {
                        ForEach([3.0, 5, 10, 25], id: \.self) { minutes in
                            emptyStateChip(Text("\(Int(minutes)) min"), symbol: nil) {
                                startNew(TimerPayload.compose(label: "", kind: .timer, minutes: minutes, targetDate: Date()))
                            }
                        }
                    } else {
                        ForEach(recents) { recent in
                            emptyStateChip(Text(recent.title), symbol: recent.isSequence ? recent.symbolName : nil) {
                                startNew(recent.payload())
                                RecentTimersStore.record(recent)
                                RecentTimersSync.refresh()
                            }
                        }
                    }
                }
                Text("Timers shared with you in Messages show up here too.")
                    .font(.footnote)
                    .foregroundStyle(Sky.roomInk)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Sky.room.ignoresSafeArea())
    }

    private func emptyStateChip(_ title: Text, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                title
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.white.opacity(0.14), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Starts right away")
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
                // Same acknowledgment as the detail screen's Stop. The banner covers every
                // timer that's ringing, so record it for each finished one.
                for payload in timers where payload.isExpired {
                    TimerStore.acknowledgeFinish(id: payload.id)
                }
            }
            .buttonStyle(.glassPill)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
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
        if !justStarted.isEmpty { TimerSpotlightIndex.shared.requestRefresh() }
        // Assigned only on change: these drive the list's re-evaluation now that it has
        // no TimelineView of its own.
        let nowPending = Set(timers.filter { $0.isPending(at: date) }.map(\.id))
        if nowPending != pendingIDs { pendingIDs = nowPending }
        for payload in justStarted where !AlarmController.ownsAlert(for: payload) {
            LiveActivityController.start(for: payload)
        }

        let stillRunning = Set(timers.filter { !$0.isExpired }.map(\.id))
        let justFinished = armedIDs.subtracting(stillRunning)
        if stillRunning != armedIDs { armedIDs = stillRunning }
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
        // Plain timers only: a sequence's custom Live Activity carries on into the next
        // phase (armAlerts below updates it in place). Exhausted sequences are ended on
        // the next launch/foreground pass.
        LiveActivityController.endFinished(finished.filter { $0.sequence == nil && !AlarmController.ownsAlert(for: $0) })
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
        // While AlarmKit itself is presenting this payload's alert, advance and persist
        // but don't re-arm: the following phases are already pre-armed (see
        // AlarmController.performSequenceReschedule) at exactly the dates
        // `advancedSequence` derives, and touching AlarmKit from this tick is what used
        // to cancel the just-presented alert out from under the user (confirmed on
        // device, back when every phase shared one alarm id).
        for payload in finished where payload.sequence != nil || payload.recurrence != nil {
            let advanced = payload.advancedSequence(at: date)
            apply(advanced, action: "sequenceAdvanced", rearm: payload.recurrence != nil || !AlarmController.alarmKitOwnsAlert(for: payload))
            if !advanced.isExpired {
                armedIDs.insert(advanced.id)
            }
        }
    }

    /// The card plus how it opens: on iPhone a hidden NavigationLink behind it (a
    /// visible one draws the gray chevron outside the sky); on iPad a tap that selects
    /// it for the detail column, outlined while shown. Separate branches on purpose —
    /// a tap gesture installed on iPhone rows too (even with a gated body) can take the
    /// tap away from the NavigationLink.
    @ViewBuilder private func selectableCard(_ payload: TimerPayload) -> some View {
        let card = LiveSkyCard(payload: payload)
            .accessibilityAddTraits(.isButton)
            // C9 · A: landscape (and iPad) cards stop at 560 pt, centered.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        if isRegular {
            card
                .contentShape(Rectangle())
                .onTapGesture { navigationPath = [payload.id] }
                .overlay {
                    if navigationPath.last == payload.id {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                            .frame(maxWidth: 560)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            card.background(NavigationLink("", value: payload.id).opacity(0))
        }
    }

    private func row(for payload: TimerPayload) -> some View {
        selectableCard(payload)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        // No full swipe: removing a timer shared with you can't be redone from here.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                requestDelete(payload)
            } label: {
                Label(removalTitle(for: payload), systemImage: "trash")
            }
            // Explicit tint: with a clear listRowBackground the destructive role's
            // default red fill drops out and the button reveals as a white slab.
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            // A view-only share offers no changes — only Delete (remove from this phone).
            if TimerStore.isReadOnly(id: payload.id) {
                EmptyView()
            } else if payload.isFinished {
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
            if payload.sequence.map(TimerSequenceWire.isValid) ?? true {
                Button {
                    withDisplayName { sharingPayload = payload }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
            }
            if CloudLinkStore.get(timerID: payload.id)?.isShared == true {
                Button {
                    manageSharing(payload)
                } label: {
                    Label("Manage Sharing", systemImage: "person.2")
                }
            }
            // View only: the change items show but are disabled (see swipeActions).
            Group {
            if payload.sequence == nil {
                Button {
                    editingPayload = payload
                } label: {
                    Label("Edit…", systemImage: "pencil")
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
                Menu {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { minutes in
                        Button(String(localized: "+\(minutes) min")) { extend(payload, by: TimeInterval(minutes * 60)) }
                    }
                    Button(String(localized: "Custom…")) { customExtendPayload = payload }
                } label: {
                    Label(String(localized: "Add Time"), systemImage: "plus")
                }
            }
            }
            .disabled(TimerStore.isReadOnly(id: payload.id))
            Button(role: .destructive) {
                requestDelete(payload)
            } label: {
                Label(removalTitle(for: payload), systemImage: "trash")
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

    /// Same wording as the detail screen: the owner of a shared timer deletes it for
    /// everyone (after confirming), someone it was shared with only removes their copy.
    private func removalTitle(for payload: TimerPayload) -> String {
        guard let link = CloudLinkStore.get(timerID: payload.id), link.isShared else { return String(localized: "Delete") }
        return link.isOwner ? String(localized: "Delete for Everyone") : String(localized: "Remove from My Timers")
    }

    private func rearmAfterSharingChange(ids: [String]) {
        timers = TimerStore.loadAll()
        for payload in timers where ids.contains(payload.id) && !payload.isExpired {
            armAlerts(for: payload)
        }
        WatchSyncController.pushCurrentState()
    }

    private func manageSharing(_ payload: TimerPayload) {
        CloudSyncController.fetchShare(for: payload) { result in
            if let (share, container) = result {
                managedShare = (CloudShareItem(share: share, container: container), payload.id)
            }
        }
    }

    private func requestDelete(_ payload: TimerPayload) {
        if let link = CloudLinkStore.get(timerID: payload.id), link.isOwner, link.isShared {
            deleteForEveryonePayload = payload
        } else {
            delete(payload)
        }
    }

    private func delete(_ payload: TimerPayload) {
        let link = CloudLinkStore.get(timerID: payload.id)
        stopInAppAlertIfRinging(for: payload.id)
        TimerStore.delete(id: payload.id)
        TimerReminders.cancel(id: payload.id)
        AlarmController.clear(payload)
        LiveActivityController.end(id: payload.id)
        WatchSyncController.pushCurrentState()
        timers.removeAll { $0.id == payload.id }
        // iPad: don't leave the detail column on a deleted timer.
        navigationPath.removeAll { $0 == payload.id }
        if let link, link.isOwner, link.isShared {
            // Already confirmed in a dialog, and it reaches everyone — no Undo.
            CloudSyncController.pushDelete(id: payload.id)
            return
        }
        // A share stays joined while Undo is offered, marked left so a pull in the
        // meantime doesn't bring the timer back; `finishUndoableDeletion` drops it.
        if link != nil { CloudLinkStore.markLeft(timerID: payload.id) }
        finishUndoableDeletion()
        undoableDeletion = payload
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            finishUndoableDeletion()
        }
    }

    private func finishUndoableDeletion() {
        undoTask?.cancel()
        undoTask = nil
        guard let deleted = undoableDeletion else { return }
        undoableDeletion = nil
        // Participant: drops the CloudLink (never the shared record). Local: no-op.
        CloudSyncController.pushDelete(id: deleted.id)
    }

    private func undoDeletion() {
        undoTask?.cancel()
        undoTask = nil
        guard let deleted = undoableDeletion else { return }
        undoableDeletion = nil
        CloudLinkStore.clearLeft(timerID: deleted.id)
        let restored = deleted.advancedSequence()
        TimerStore.save(restored)
        armAlerts(for: restored)
        timers.append(restored)
        if !restored.isExpired { armedIDs.insert(restored.id) }
        WatchSyncController.pushCurrentState()
        // `TimerStore.delete` cleared the view-only flag; read it back from CloudKit.
        if CloudLinkStore.get(timerID: restored.id) != nil {
            CloudSyncController.refreshPermissions(for: [restored.id]) { timers = TimerStore.loadAll() }
        }
    }

    private func undoToast(for payload: TimerPayload) -> some View {
        HStack {
            Text("Removed “\(payload.label)”")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Button("Undo") { undoDeletion() }
                .buttonStyle(.glassPill)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    /// Deleting (locally, or remotely via CloudKit) a timer whose in-app alarm /
    /// vibration loop is sounding used to leave it — and the "Time's up" banner —
    /// running for a timer that no longer exists. Stops them when the deleted timer is
    /// finished and no other finished-and-still-ringing timer remains to justify them.
    private func stopInAppAlertIfRinging(for id: String) {
        guard alarm.isPlaying || vibration.isVibrating,
              timers.first(where: { $0.id == id })?.isFinished == true else { return }
        let othersFinished = timers.contains { $0.id != id && $0.isExpired && !TimerStore.isFinishAcknowledged(id: $0.id) && armedRecently($0) }
        if !othersFinished {
            alarm.stop()
            vibration.stop()
        }
        armedIDs.remove(id)
    }

    /// Finished within the last minute — the window in which another timer could
    /// plausibly be the one actually ringing.
    private func armedRecently(_ payload: TimerPayload) -> Bool {
        payload.endDate > Date().addingTimeInterval(-60)
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

    /// Edit sheet save. A countdown moved from finished to a future date is running
    /// again — silence its in-app alert first (needs the pre-edit, finished copy still
    /// in `timers`), the same cleanup `repeatTimer` does.
    private func applyEdit(_ edited: TimerPayload) {
        if timers.first(where: { $0.id == edited.id })?.isFinished == true && !edited.isFinished {
            stopInAppAlertIfRinging(for: edited.id)
        }
        applyMutation(edited, action: "edited")
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
        // View-only share: the controls are hidden, and CloudKit would refuse the write.
        guard !TimerStore.isReadOnly(id: updated.id) else { return }
        apply(updated, action: action)
        // Shared with a FaceTime call (SharePlayController): tell the others.
        SharePlayController.shared.send(updated)
        if CloudLinkStore.get(timerID: updated.id)?.isShared == true {
            promptForNameIfNeeded()
        }
    }

    /// Fire-and-forget version for call sites that don't need to wait on the result
    /// (mutations — see applyMutation). No-ops if a name is already set.
    private func promptForNameIfNeeded() {
        guard DisplayNameStore.shouldPrompt else { return }
        showingNamePrompt = true
    }

    /// Runs `then` immediately if a display name is already set (DisplayNameStore); else
    /// prompts once and runs `then` after Continue/Skip. Only used for the Share… flow,
    /// where the prompt has to resolve before the share sheet opens (two presentations at
    /// once would fight each other) — see DisplayNameStore.swift for the skip fallback.
    private func withDisplayName(_ then: @escaping () -> Void) {
        guard DisplayNameStore.shouldPrompt else {
            then()
            return
        }
        pendingNameCompletion = then
        showingNamePrompt = true
    }

    /// `rearm: false` only for the foreground tick's sequence advance while AlarmKit is
    /// presenting the just-finished phase's alert — see checkForNewlyExpired.
    private func apply(_ updated: TimerPayload, action: String = "updated", rearm: Bool = true) {
        TimerStore.save(updated)
        if rearm {
            armAlerts(for: updated)
        }
        // Advancing by the clock is a projection of the same shared schedule, not
        // a user mutation. Pushing it could overwrite a remote pause/step/extend.
        if action != "sequenceAdvanced" { CloudSyncController.pushUp(updated, action: action) }
        WatchSyncController.pushCurrentState()
        if let index = timers.firstIndex(where: { $0.id == updated.id }) {
            timers[index] = updated
        } else {
            timers.append(updated)
        }
        // An open TimerDetailView (always on screen on iPad, beside the list) holds its
        // own @State copy: a swipe/context-menu change here left it stale, and its next
        // tap saved that stale copy back — un-pausing, reverting an Edit, for everyone.
        // Not for the clock-driven advance: the detail advances on its own tick, and this
        // view's observer would stop an in-app phase alert that just started ringing.
        if action != "sequenceAdvanced" {
            NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
        }
    }

    /// A newly created plain timer/countdown (sheet, recent chip, Quick Action): apply it
    /// and remember it in RecentTimersStore (timers only — see that file).
    private func startNew(_ payload: TimerPayload) {
        apply(payload)
        RecentTimersStore.record(payload)
        RecentTimersSync.refresh()
    }

    private func openQuickAction(_ type: String) {
        if type.hasPrefix(RecentTimersSync.quickActionPrefix) {
            let id = String(type.dropFirst(RecentTimersSync.quickActionPrefix.count))
            if let recent = RecentTimersStore.all().first(where: { $0.id == id }) {
                startNew(recent.payload())
                RecentTimersStore.record(recent)
                RecentTimersSync.refresh()
            }
            return
        }
        switch type {
        case "newTimer": pendingNewTimerKind = .timer
        case "newCountdown": pendingNewTimerKind = .countdown
        default: return
        }
    }

    /// A timer from a SharePlay session: added if new, adopted only when its `upd`
    /// stamp is newer than ours (same rule as a re-opened link).
    private func receiveFromSharePlay(_ parsed: TimerPayload) {
        // Same rules as a re-opened link (handleIncoming): CloudKit is authoritative for a
        // linked timer — adopting the call's copy re-pushed every field, overwrote who
        // changed it, and rolled back a newer change from someone outside the call — and
        // a view-only share can't be changed here at all.
        // `isShared`, not "has a link": a timer merely synced between this person's own
        // devices has an owner link too, and must still follow the call.
        if CloudLinkStore.get(timerID: parsed.id)?.isShared == true || TimerStore.isReadOnly(id: parsed.id) { return }
        if let stored = timers.first(where: { $0.id == parsed.id }), !stored.shouldAdopt(parsed) { return }
        apply(parsed.advancedSequence(), action: "updatedFromLink")
    }

    /// Runs when the add-confirmation sheet closes (Add, Not Now or a swipe). A timer
    /// still missing from the store was declined: leave its share the same way
    /// "Remove from My Timers" does (`pushDelete` on a participant link only marks it
    /// left and drops the CloudLink — it never touches the shared record).
    private func leaveDeclinedShares() {
        let stored = Set(TimerStore.loadAll().map(\.id))
        if let offered = incomingPayload?.id ?? lastOfferedShareID, !stored.contains(offered) {
            declinedShareIDs.insert(offered)
        }
        lastOfferedShareID = nil
        for id in declinedShareIDs where !stored.contains(id) {
            if let link = CloudLinkStore.get(timerID: id), !link.isOwner {
                CloudSyncController.pushDelete(id: id)
            }
        }
    }

    /// Universal link / App Clip handoff into the full app. A timer already in the local
    /// store adopts the link's snapshot only when its `upd` stamp is strictly newer and
    /// the timer has no CloudLink (`shouldAdopt`; same in the Messages extension); a
    /// genuinely new one surfaces the add-confirmation sheet instead of merging straight in.
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
        // Opening the link again is a fresh offer, even after an earlier Not Now.
        declinedShareIDs.remove(parsed.id)
        if let stored = timers.first(where: { $0.id == parsed.id }) {
            // A re-shared plain link carrying newer state (the sender extended/paused
            // and sent it again) updates the copy we have. CloudKit-linked timers are
            // already kept current by sync — never let a link snapshot override that.
            if CloudLinkStore.get(timerID: parsed.id) == nil, stored.shouldAdopt(parsed) {
                apply(parsed, action: "updatedFromLink")
            }
        } else {
            incomingPayload = parsed
            lastOfferedShareID = parsed.id
        }

        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let shareString = components.queryItems?.first(where: { $0.name == "ckshare" })?.value,
              let shareURL = URL(string: shareString) else { return }

        CloudSyncController.acceptShare(from: shareURL) { authoritative in
            guard let authoritative else { return }
            DispatchQueue.main.async {
                if declinedShareIDs.contains(authoritative.id) {
                    // Not Now was tapped while the accept was still in flight.
                    leaveDeclinedShares()
                    return
                }
                if incomingPayload?.id == authoritative.id {
                    // Still showing the add-confirmation sheet for this timer — upgrade
                    // it to the authoritative cloud state before the user taps Add.
                    incomingPayload = authoritative
                } else if let local = timers.first(where: { $0.id == authoritative.id }) {
                    // Already added (e.g. re-tapping the link after accepting once, or
                    // the sender re-opening their own link) — refresh in place instead of
                    // resurfacing a sheet that's already been dismissed. A change made here
                    // while the accept was in flight (it couldn't push: no CloudLink yet)
                    // is newer than the record — keep it and push it now instead.
                    if authoritative.shouldAdopt(local) {
                        CloudSyncController.pushUp(local, action: "updated")
                        return
                    }
                    TimerStore.save(authoritative)
                    armAlerts(for: authoritative)
                    if let index = timers.firstIndex(where: { $0.id == authoritative.id }) { timers[index] = authoritative }
                    WatchSyncController.pushCurrentState()
                    // An open detail screen holds its own copy — tell it (same as the
                    // foreground reload and pullCloudChanges).
                    NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
                }
            }
        }
    }

    /// What the armed alert depends on — a difference means it's out of date.
    private static func alertShape(_ payload: TimerPayload) -> String {
        "\(payload.endDate.timeIntervalSince1970)|\(payload.pausedRemaining ?? -1)|\(payload.alarmEnabled)|\(payload.vibrationEnabled)|\(payload.label)"
            + "|\(payload.sequence?.phaseIndex ?? -1)|\(payload.sequence?.loopIndex ?? -1)"
    }

    /// Applies remote changes pulled from CloudKit through the same local mutation
    /// sequence every other surface uses, then folds the results into the visible list.
    private func pullCloudChanges() {
        CloudSyncController.retryPendingDeletes()
        CloudSyncController.pullChanges { updated, deletedIDs in
            DispatchQueue.main.async {
                TimerStore.save(contentsOf: updated)
                for payload in updated {
                    // Before the reassign below: it reads the old (finished) copy.
                    if !payload.isFinished { stopInAppAlertIfRinging(for: payload.id) }
                    armAlerts(for: payload)
                    if let index = timers.firstIndex(where: { $0.id == payload.id }) {
                        timers[index] = payload
                    } else {
                        timers.append(payload)
                    }
                }
                for id in deletedIDs {
                    stopInAppAlertIfRinging(for: id)
                    TimerStore.delete(id: id)
                    TimerReminders.cancel(id: id)
                    AlarmController.clear(id: id)
                    LiveActivityController.end(id: id)
                    timers.removeAll { $0.id == id }
                }
                // Same reason as the scenePhase post: refresh an open detail screen.
                if !updated.isEmpty || !deletedIDs.isEmpty {
                    NotificationCenter.default.post(name: .externalTimerStoreChange, object: nil)
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

/// A list card that ticks by itself, so the list around it (sections, swipe actions,
/// context menus) isn't rebuilt every second. Paused and finished cards don't change
/// from second to second; they redraw once a minute (and whenever the list hands them
/// a new payload).
private struct LiveSkyCard: View {
    let payload: TimerPayload

    var body: some View {
        // Overtime (a finished timer's "+2:13") still ticks every second for its hour.
        TimelineView(.periodic(from: .now, by: payload.isPaused || (payload.isFinished && payload.overtime() == nil) ? 60 : 1)) { context in
            SkyCard(payload: payload, date: context.date)
        }
    }
}

/// A kind tile on the empty list (C7 · A): the kind's sky, its name, one line about
/// it and a sample of what its digits look like.
private struct EmptyStateTile: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let sample: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).skyLabel(12)
                    Text(detail).font(.footnote).opacity(0.9)
                }
                Spacer(minLength: 8)
                Text(verbatim: sample)
                    .skyDigits(28, weight: .regular)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(SkyCornerScrim())
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
