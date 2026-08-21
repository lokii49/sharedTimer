//
//  ContentView.swift
//  sharedTimer
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var timers: [TimerPayload] = TimerStore.loadAll()
    @State private var showingNewTimer = false
    @State private var pendingNewTimerKind: TimerKind = .timer
    @State private var sharingPayload: TimerPayload?
    @State private var incomingPayload: TimerPayload?
    @State private var showingNamePrompt = false
    @State private var nameInput: String = ""
    @State private var pendingNameCompletion: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Group {
                    if timers.isEmpty {
                        emptyState
                    } else {
                        List {
                            let active = timers.filter { !$0.isExpired }.sorted { $0.endDate < $1.endDate }
                            let expired = timers.filter { $0.isExpired }.sorted { $0.endDate > $1.endDate }

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
            }
            .navigationTitle("Timers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewTimer = true
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
        .onAppear {
            timers = TimerStore.loadAll()
            for payload in timers where !payload.isExpired {
                NotificationScheduler.scheduleAlert(for: payload)
                if !payload.isPaused {
                    LiveActivityController.start(for: payload)
                }
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
            guard newPhase == .active else { return }
            // Re-read TimerStore first — a timer created while backgrounded (e.g. via
            // TimerIntents.swift's Siri intents) writes straight to the App Group and has
            // no CloudLink, so pullCloudChanges alone would never surface it here.
            timers = TimerStore.loadAll()
            pullCloudChanges()
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
        }
        .swipeActions(edge: .leading) {
            if !payload.isExpired {
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
            Button {
                withDisplayName { sharingPayload = payload }
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            if !payload.isExpired {
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

    private func delete(_ payload: TimerPayload) {
        TimerStore.delete(id: payload.id)
        NotificationScheduler.cancel(id: payload.id)
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
        NotificationScheduler.cancel(id: updated.id)
        if !updated.isPaused {
            NotificationScheduler.scheduleAlert(for: updated)
            LiveActivityController.start(for: updated)
        } else {
            LiveActivityController.update(for: updated)
        }
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
                    NotificationScheduler.cancel(id: payload.id)
                    if payload.isPaused {
                        LiveActivityController.update(for: payload)
                    } else {
                        NotificationScheduler.scheduleAlert(for: payload)
                        LiveActivityController.start(for: payload)
                    }
                    if let index = timers.firstIndex(where: { $0.id == payload.id }) {
                        timers[index] = payload
                    } else {
                        timers.append(payload)
                    }
                }
                for id in deletedIDs {
                    TimerStore.delete(id: id)
                    NotificationScheduler.cancel(id: id)
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
    @FocusState private var labelFocused: Bool

    let onCreate: (TimerPayload) -> Void

    init(initialKind: TimerKind = .timer, onCreate: @escaping (TimerPayload) -> Void) {
        self._kind = State(initialValue: initialKind)
        self.onCreate = onCreate
    }

    /// Live preview of the sky this timer will get.
    private var previewPayload: TimerPayload {
        TimerPayload.compose(label: label.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : label,
                             kind: kind, minutes: minutes, targetDate: targetDate)
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
                    labelFocused: $labelFocused
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
                        onCreate(TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: payload.url()) {
                    Image(systemName: "square.and.arrow.up")
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
