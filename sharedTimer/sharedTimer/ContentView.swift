//
//  ContentView.swift
//  sharedTimer
//

import SwiftUI

struct ContentView: View {
    @State private var timers: [TimerPayload] = TimerStore.loadAll()

    var body: some View {
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
        .onAppear {
            timers = TimerStore.loadAll()
            for payload in timers where !payload.isExpired {
                NotificationScheduler.scheduleAlert(for: payload)
                if !payload.isPaused {
                    LiveActivityController.start(for: payload)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 48))
            Text("SharedTimer")
                .font(.title2.bold())
            Text("Open this app inside iMessage to share a timer.")
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
                Text(payload.label)
                    .font(.body.weight(.medium))
                Text(statusText(for: payload))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(timeString(remaining > 0 ? remaining : payload.duration))
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
            return "paused at \(timeString(payload.remaining))"
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
        }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    ContentView()
}
