//
//  TimerRunningView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerRunningView: View {
    @State private var payload: TimerPayload
    let onNewTimer: () -> Void
    let onUpdate: (TimerPayload) -> Void
    let onDelete: (TimerPayload) -> Void

    init(payload: TimerPayload,
         onNewTimer: @escaping () -> Void,
         onUpdate: @escaping (TimerPayload) -> Void,
         onDelete: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self.onNewTimer = onNewTimer
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let done = payload.isExpired

            ZStack {
                Sky.gradient(for: payload, at: context.date)
                    .ignoresSafeArea()

                VStack {
                    Spacer()

                    VStack(spacing: 8) {
                        Text(payload.label)
                            .skyLabel(12)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(TimeFormat.display(remaining))
                            .skyDigits(52, weight: .thin)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .padding(.horizontal, 20)
                        Text(subtitle(done: done))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(done ? "Timer finished" : "This matches what your friend sees")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 2)
                    }

                    Spacer()

                    if !done {
                        HStack(spacing: 10) {
                            Button(payload.isPaused ? "Resume" : "Pause") {
                                togglePause()
                            }
                            .buttonStyle(.glassPill)

                            Button("+1:00") {
                                extend(by: 60)
                            }
                            .buttonStyle(.glassPill)
                        }
                    }

                    HStack(spacing: 22) {
                        Button {
                            onNewTimer()
                        } label: {
                            Label("New Timer", systemImage: "plus.circle")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Button {
                            onDelete(payload)
                        } label: {
                            Text("Delete")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 18)
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
