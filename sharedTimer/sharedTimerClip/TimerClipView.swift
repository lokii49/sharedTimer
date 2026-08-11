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
                        .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.9), value: progress)

                    VStack(spacing: 4) {
                        Text(TimeFormat.remaining(remaining))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
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

}
