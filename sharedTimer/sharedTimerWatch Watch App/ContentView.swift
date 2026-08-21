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

    private var active: [TimerPayload] {
        sync.timers.filter { !$0.isExpired }.sorted { $0.endDate < $1.endDate }
    }

    var body: some View {
        NavigationStack {
            Group {
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
                }
            }
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
                Text(payload.isPaused ? "Paused" : TimeFormat.display(payload.remaining, at: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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

                Text(payload.isPaused ? "Paused" : TimeFormat.display(remaining, at: context.date))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if !done {
                    HStack(spacing: 8) {
                        Button(payload.isPaused ? "Resume" : "Pause") {
                            sync.send(id: payload.id, op: payload.isPaused ? "resume" : "pause")
                        }
                        Button("+1:00") {
                            sync.send(id: payload.id, op: "extend")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
