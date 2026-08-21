//
//  ContentView.swift
//  sharedTimer
//

import SwiftUI

struct ContentView: View {
    @State private var timers: [TimerPayload] = TimerStore.loadAll()
    @State private var showingNewTimer = false
    @State private var sharingPayload: TimerPayload?
    @State private var incomingPayload: TimerPayload?
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
                NewTimerSheet { payload in
                    apply(payload)
                }
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
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
                    TimerDetailView(payload: payload, onUpdate: apply, onDelete: delete)
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
                sharingPayload = payload
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
        timers.removeAll { $0.id == payload.id }
    }

    private func togglePause(_ payload: TimerPayload) {
        let updated = payload.isPaused ? payload.resumed() : payload.paused()
        apply(updated)
    }

    private func extend(_ payload: TimerPayload, by interval: TimeInterval) {
        apply(payload.extended(by: interval))
    }

    private func apply(_ updated: TimerPayload) {
        TimerStore.save(updated)
        NotificationScheduler.cancel(id: updated.id)
        if !updated.isPaused {
            NotificationScheduler.scheduleAlert(for: updated)
            LiveActivityController.start(for: updated)
        } else {
            LiveActivityController.update(for: updated)
        }
        CloudSyncController.pushUp(updated)
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
            }
        }
    }
}

private struct NewTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var kind: TimerKind = .timer
    @State private var minutes: Double = 5
    @State private var targetDate: Date = Date().addingTimeInterval(86400)
    @FocusState private var labelFocused: Bool

    let onCreate: (TimerPayload) -> Void

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
    let onUpdate: (TimerPayload) -> Void
    let onDelete: (TimerPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(payload: TimerPayload, onUpdate: @escaping (TimerPayload) -> Void, onDelete: @escaping (TimerPayload) -> Void) {
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
        onUpdate(payload)
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload)
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
