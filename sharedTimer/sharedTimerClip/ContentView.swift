//
//  ContentView.swift
//  sharedTimerClip
//

import SwiftUI
import StoreKit

struct ContentView: View {
    @State private var payload: TimerPayload?

    var body: some View {
        Group {
            if let payload {
                TimerClipView(payload: payload)
            } else {
                emptyState
            }
        }
        .onOpenURL { url in
            handle(url: url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            handle(url: activity.webpageURL)
        }
        .task {
            presentAppStoreOverlay()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("SharedTimer")
                .font(.title2.bold())
            Text("Open a shared timer link to see the live countdown.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private func handle(url: URL?) {
        guard let parsed = TimerPayload.from(url: url) else { return }
        let stored = TimerStore.loadAll().first { $0.id == parsed.id } ?? parsed
        TimerStore.save(stored)
        NotificationScheduler.scheduleAlert(for: stored)
        payload = stored
    }

    private func presentAppStoreOverlay() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        let config = SKOverlay.AppClipConfiguration(position: .bottom)
        SKOverlay.present(in: scene, configuration: config)
    }
}

#Preview {
    ContentView()
}
