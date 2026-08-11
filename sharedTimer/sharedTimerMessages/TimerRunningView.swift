//
//  TimerRunningView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerRunningView: View {
    @State private var payload: TimerPayload
    @State private var isAdded: Bool
    let onNewTimer: () -> Void
    let onAdd: (TimerPayload) -> Void
    let onUpdate: (TimerPayload) -> Void
    let onDelete: (TimerPayload) -> Void

    init(payload: TimerPayload,
         isAdded: Bool,
         onNewTimer: @escaping () -> Void,
         onAdd: @escaping (TimerPayload) -> Void,
         onUpdate: @escaping (TimerPayload) -> Void,
         onDelete: @escaping (TimerPayload) -> Void) {
        self._payload = State(initialValue: payload)
        self._isAdded = State(initialValue: isAdded)
        self.onNewTimer = onNewTimer
        self.onAdd = onAdd
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let progress = payload.progress(at: context.date)
            let done = payload.isExpired
            let tint = ringColor(for: progress, done: done)

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 4) {
                        Text(payload.label)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        if payload.kind == .countdown {
                            Text("→ \(TimeFormat.targetDate(payload.endDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)

                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 14)

                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                tint,
                                style: StrokeStyle(lineWidth: 14, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.9), value: progress)

                        VStack(spacing: 4) {
                            Text(TimeFormat.remaining(remaining))
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .foregroundStyle(done ? .red : .primary)

                            Text(done ? "TIME'S UP" : (payload.isPaused ? "PAUSED" : "REMAINING"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1)
                        }
                    }
                    .frame(width: 200, height: 200)
                    .padding(.vertical, 4)

                    Label(
                        statusLine(done: done),
                        systemImage: done ? "checkmark.circle.fill" : (isAdded ? "arrow.triangle.2.circlepath" : "person.crop.circle.badge.plus")
                    )
                    .font(.footnote)
                    .foregroundStyle(done ? .red : .secondary)
                    .multilineTextAlignment(.center)

                    if !done {
                        if isAdded {
                            HStack(spacing: 12) {
                                controlButton(
                                    title: payload.isPaused ? "Resume" : "Pause",
                                    systemImage: payload.isPaused ? "play.fill" : "pause.fill"
                                ) {
                                    togglePause()
                                }

                                controlButton(title: "+1 min", systemImage: "plus") {
                                    extend(by: 60)
                                }
                            }
                            .padding(.horizontal, 24)
                        } else {
                            Button {
                                isAdded = true
                                onAdd(payload)
                            } label: {
                                Label("Add to My Timers", systemImage: "plus.circle.fill")
                                    .font(.system(.body, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .padding(.horizontal, 24)
                        }
                    }

                    Button(action: onNewTimer) {
                        Label("New Timer", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .padding(.horizontal, 32)

                    if isAdded {
                        Button(role: .destructive) {
                            onDelete(payload)
                        } label: {
                            Label("Delete Timer", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func statusLine(done: Bool) -> String {
        if done {
            return "Timer finished"
        }
        if isAdded {
            return "This matches what your friend sees"
        }
        return "Shared with you — add it to get reminders and a live countdown"
    }

    private func controlButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
    }

    private func togglePause() {
        payload = payload.isPaused ? payload.resumed() : payload.paused()
        onUpdate(payload)
    }

    private func extend(by interval: TimeInterval) {
        payload = payload.extended(by: interval)
        onUpdate(payload)
    }

    private func ringColor(for progress: Double, done: Bool) -> Color {
        if done { return .red }
        if payload.isPaused { return .orange }
        if progress < 0.15 { return .red }
        if progress < 0.4 { return .orange }
        return .accentColor
    }

}
