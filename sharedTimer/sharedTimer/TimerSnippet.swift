//
//  TimerSnippet.swift
//  sharedTimer
//
//  Interactive Siri / Shortcuts / Spotlight card (1.0.7, D7): "How long is left on
//  Pasta?" answers with the timer's sky, a live countdown and Pause/Resume + "+1:00",
//  built on the iOS 26 snippet-intent API. Main app only. The buttons run the same
//  actions as the Live Activity and Siri (SetTimerPausedIntent →
//  LiveActivityActions; ExtendFromSnippetIntent → TimerIntentActions), then reload the
//  card. A view-only share shows no buttons.
//

import AppIntents
import SwiftUI

struct TimerStatusSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Timer Status"
    static let isDiscoverable = false

    @Parameter(title: "Timer") var timer: TimerChoice

    init() {}
    init(timer: TimerChoice) { self.timer = timer }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let payload = TimerStore.loadAll().first { $0.id == timer.id }?.advancedSequence()
        return .result(view: TimerSnippetView(payload: payload, readOnly: TimerStore.isReadOnly(id: timer.id)))
    }
}

/// The card's "+1:00". Not discoverable on its own — Extend Timer is the Shortcuts
/// action for that.
struct ExtendFromSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Minute"
    static let isDiscoverable = false

    @Parameter(title: "Timer ID") var timerID: String

    init() { timerID = "" }
    init(timerID: String) { self.timerID = timerID }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await TimerIntentActions.perform(timerID: timerID, mutation: .extend(minutes: 1))
        TimerStatusSnippetIntent.reload()
        return .result()
    }
}

struct TimerSnippetView: View {
    let payload: TimerPayload?
    let readOnly: Bool

    var body: some View {
        if let payload {
            card(payload)
        } else {
            Label("Timer unavailable", systemImage: "timer")
                .padding()
        }
    }

    private func card(_ payload: TimerPayload) -> some View {
        let now = Date()
        let pending = payload.isPending(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(payload.label).skyLabel(12).lineLimit(1)
                Spacer()
                if pending {
                    Text("Scheduled").skyLabel(11)
                } else if payload.isPaused {
                    Text("Paused").skyLabel(11)
                } else if payload.isFinished {
                    Text("Time's up").skyLabel(11)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            digits(payload, now: now, pending: pending)
                .font(.system(size: 44, weight: .thin))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)

            if !readOnly && !pending && !payload.isFinished {
                HStack(spacing: 12) {
                    Button(intent: ExtendFromSnippetIntent(timerID: payload.id)) {
                        Text("+1:00")
                    }
                    Button(intent: SetTimerPausedIntent(timerID: payload.id, paused: !payload.isPaused)) {
                        Text(payload.isPaused ? "Resume" : "Pause")
                    }
                }
                .buttonStyle(.glassPill)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Sky.gradient(for: payload, at: now), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func digits(_ payload: TimerPayload, now: Date, pending: Bool) -> some View {
        if pending, let start = payload.scheduledStartDate {
            Text(Sky.pendingStartText(for: start, at: now))
        } else if !payload.isPaused && !payload.isFinished && payload.remaining < 86_400 {
            // Ticks by itself — the card isn't re-rendered every second.
            Text(timerInterval: now...payload.endDate, countsDown: true)
        } else if payload.isFinished {
            Text(TimeFormat.display(0))
        } else {
            Text(TimeFormat.display(payload.remaining))
        }
    }
}
