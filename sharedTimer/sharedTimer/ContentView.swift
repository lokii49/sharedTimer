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
        let remaining = payload.endDate.timeIntervalSince(date)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.label)
                    .font(.body.weight(.medium))
                Text(remaining > 0
                     ? "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"
                     : "finished \(payload.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(timeString(remaining))
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remaining > 0 ? .primary : .secondary)
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
