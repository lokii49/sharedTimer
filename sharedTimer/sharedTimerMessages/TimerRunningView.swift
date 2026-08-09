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

            VStack(spacing: 16) {
                Text(payload.label)
                    .font(.headline)

                Text(timeString(remaining))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(remaining <= 0 ? .red : .primary)
                    .monospacedDigit()

                Text(remaining <= 0 ? "Time's up!" : "Sent — this is exactly what your friend sees when they open the link.")
                    .font(.footnote)
                    .foregroundStyle(remaining <= 0 ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("New Timer", action: onNewTimer)
                    .buttonStyle(.bordered)
            }
            .padding()
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
