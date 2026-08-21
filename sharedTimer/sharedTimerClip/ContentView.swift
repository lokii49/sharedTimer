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
        ZStack {
            Sky.room.ignoresSafeArea()
            ContentUnavailableView {
                Label("Timer Duo", systemImage: "timer")
            } description: {
                Text("Open a shared timer link to see the live countdown.")
            }
        }
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
        let overlay = SKOverlay(configuration: config)
        overlay.present(in: scene)
    }
}

#Preview {
    ContentView()
}
