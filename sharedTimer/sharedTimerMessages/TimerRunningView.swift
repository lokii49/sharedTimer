//
//  TimerRunningView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerRunningView: View {
    let payload: TimerPayload
    let onNewTimer: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.endDate.timeIntervalSince(context.date)
            let progress = payload.progress(at: context.date)
            let done = remaining <= 0
            let tint = ringColor(for: progress, done: done)

            ScrollView {
                VStack(spacing: 28) {
                    Text(payload.label)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
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
                            Text(timeString(remaining))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(done ? .red : .primary)

                            Text(done ? "TIME'S UP" : "REMAINING")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(1)
                        }
                    }
                    .frame(width: 200, height: 200)
                    .padding(.vertical, 4)

                    Label(
                        done ? "Timer finished" : "This matches what your friend sees",
                        systemImage: done ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.footnote)
                    .foregroundStyle(done ? .red : .secondary)

                    Button(action: onNewTimer) {
                        Label("New Timer", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func ringColor(for progress: Double, done: Bool) -> Color {
        if done { return .red }
        if progress < 0.15 { return .red }
        if progress < 0.4 { return .orange }
        return .accentColor
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
