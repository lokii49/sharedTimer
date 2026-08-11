//
//  TimerClipView.swift
//  sharedTimerClip
//

import SwiftUI

struct TimerClipView: View {
    let payload: TimerPayload

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = payload.remaining
            let progress = payload.progress(at: context.date)
            let done = payload.isExpired
            let tint = ringColor(for: progress, done: done)

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
                        .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
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

                Label(
                    done ? "Timer finished" : "Live countdown from a shared timer",
                    systemImage: done ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(done ? .red : .secondary)

                Spacer()
            }
            .frame(maxWidth: .infinity)
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
