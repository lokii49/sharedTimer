//
//  ContentView.swift
//  sharedTimer
//

import SwiftUI

struct ContentView: View {
    @State private var timers: [TimerPayload] = TimerStore.loadAll()
    @State private var showingNewTimer = false
    @State private var incomingPayload: TimerPayload?

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
                                Section("Active") {
                                    ForEach(active) { row(for: $0, at: context.date) }
                                }
                            }
                            if !expired.isEmpty {
                                Section("Expired") {
                                    ForEach(expired) { row(for: $0, at: context.date) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("SharedTimer")
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
            .sheet(item: $incomingPayload) { payload in
                AddSharedTimerSheet(payload: payload) {
                    apply($0)
                }
            }
        }
        .onAppear {
            timers = TimerStore.loadAll()
            for payload in timers where !payload.isExpired {
                NotificationScheduler.scheduleAlert(for: payload)
                if !payload.isPaused {
                    LiveActivityController.start(for: payload)
                }
            }
        }
        .onOpenURL { url in
            handleIncoming(url: url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            handleIncoming(url: activity.webpageURL)
        }
    }

    /// A tapped shared link (Universal Link) landed us here. If we already have
    /// this timer, just leave it be — otherwise offer the recipient a chance to add it.
    private func handleIncoming(url: URL?) {
        guard let parsed = TimerPayload.from(url: url) else { return }
        guard !timers.contains(where: { $0.id == parsed.id }) else { return }
        incomingPayload = parsed
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 48))
            Text("SharedTimer")
                .font(.title2.bold())
            Text("Create a timer or countdown below, or open this app inside iMessage to share one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private func row(for payload: TimerPayload, at date: Date) -> some View {
        let remaining = payload.remaining
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(payload.label)
                        .font(.body.weight(.medium))
                } icon: {
                    Image(systemName: payload.kind == .countdown ? "calendar" : "timer")
                        .foregroundStyle(.secondary)
                }
                Text(statusText(for: payload))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TimeFormat.remaining(remaining > 0 ? remaining : payload.duration))
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(payload.isExpired ? .secondary : (payload.isPaused ? .orange : .primary))
        }
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
                .tint(.orange)

                Button {
                    extend(payload, by: 60)
                } label: {
                    Label("+1 min", systemImage: "plus")
                }
                .tint(.blue)
            }
        }
    }

    private func statusText(for payload: TimerPayload) -> String {
        if payload.isPaused {
            return "paused at \(TimeFormat.remaining(payload.remaining))"
        }
        if payload.kind == .countdown {
            return payload.remaining > 0
                ? "→ \(TimeFormat.targetDate(payload.endDate))"
                : "reached \(TimeFormat.targetDate(payload.endDate))"
        }
        if payload.remaining > 0 {
            return "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        }
        return "finished \(payload.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private func delete(_ payload: TimerPayload) {
        TimerStore.delete(id: payload.id)
        NotificationScheduler.cancel(id: payload.id)
        LiveActivityController.end(id: payload.id)
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
        if let index = timers.firstIndex(where: { $0.id == updated.id }) {
            timers[index] = updated
        } else {
            timers.append(updated)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    labelFocused: $labelFocused
                )
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let payload = TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate)
                        onCreate(payload)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct AddSharedTimerSheet: View {
    let payload: TimerPayload
    let onAdd: (TimerPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: payload.kind == .countdown ? "calendar.badge.plus" : "timer")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                VStack(spacing: 6) {
                    Text(payload.label)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    if payload.kind == .countdown {
                        Text("→ \(TimeFormat.targetDate(payload.endDate))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(TimeFormat.remaining(payload.remaining))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("Someone shared this \(payload.kind == .countdown ? "countdown" : "timer") with you. Add it to see a live countdown and get a reminder when it ends.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                Button {
                    onAdd(payload)
                    dismiss()
                } label: {
                    Label("Add to My Timers", systemImage: "plus.circle.fill")
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ContentView()
}
