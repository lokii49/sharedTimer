//
//  ContentView.swift
//  sharedTimerWatch Watch App
//
//  Native watchOS list — no Sky gradient system here yet, deliberately (see CLAUDE.md's
//  Phase 3 watch plan): the gradient system is a reasonable future polish pass, not core
//  functionality for a first watch surface.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var sync = WatchSyncController.shared

    @State private var path: [String] = []

    /// Unfinished timers, soonest first (paused ones by their frozen time left, not
    /// their stale end). Read at the tick's date, so a timer that finishes while the list
    /// is open leaves it instead of sitting at 00:00 until the next phone update.
    private func active(at date: Date) -> [TimerPayload] {
        sync.timers.filter { $0.isPaused || $0.endDate > date }
            .sorted { ($0.pausedRemaining ?? $0.endDate.timeIntervalSince(date)) < ($1.pausedRemaining ?? $1.endDate.timeIntervalSince(date)) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let active = active(at: context.date)
                if active.isEmpty {
                    emptyState
                } else {
                    List(active) { payload in
                        NavigationLink(value: payload.id) {
                            row(payload)
                        }
                    }
                }
            }
            .navigationTitle("Timers")
            .navigationDestination(for: String.self) { id in
                if let payload = sync.timers.first(where: { $0.id == id }) {
                    TimerDetailView(payload: payload)
                } else {
                    Text("Timer unavailable").foregroundStyle(.secondary)
                }
            }
        }
        .onOpenURL { url in
            if let id = WatchTimerLink.id(from: url) { path = [id] }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Timers")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ payload: TimerPayload) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(payload.label)
                .font(.headline)
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Paused shows its frozen time too, so +1:00 while paused visibly lands.
                HStack(spacing: 4) {
                    Text(TimeFormat.display(payload.remaining, at: context.date))
                        .monospacedDigit()
                    if payload.isPaused { Text("Paused") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct TimerDetailView: View {
    @ObservedObject private var sync = WatchSyncController.shared
    let payloadID: String
    @State private var lastKnown: TimerPayload

    init(payload: TimerPayload) {
        self.payloadID = payload.id
        self._lastKnown = State(initialValue: payload)
    }

    private var payload: TimerPayload {
        sync.timers.first(where: { $0.id == payloadID }) ?? lastKnown
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired

            VStack(spacing: 10) {
                Text(payload.label)
                    .font(.headline)
                    .lineLimit(1)

                Text(TimeFormat.display(remaining, at: context.date))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if payload.isPaused {
                    Text("Paused").font(.footnote).foregroundStyle(.secondary)
                }

                if !done {
                    HStack(spacing: 8) {
                        Button(payload.isPaused ? String(localized: "Resume") : String(localized: "Pause")) {
                            sync.send(id: payload.id, op: payload.isPaused ? "resume" : "pause")
                        }
                        Button("+1:00") {
                            sync.send(id: payload.id, op: "extend")
                        }
                    }
                    .buttonStyle(.bordered)
                    // Shared with the phone as view only: same as the phone, shown but
                    // disabled (the phone would refuse the change anyway).
                    .disabled(payload.readOnly)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
