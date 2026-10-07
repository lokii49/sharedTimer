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
                TimerClipView(payload: payload).id(payload.url().absoluteString)
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
                Label("Timer", systemImage: "timer")
            } description: {
                Text("Open a shared timer link to see the live countdown.")
            }
        }
    }

    private func handle(url: URL?) {
        guard let parsed = TimerPayload.from(url: url) else { return }
        let existing = TimerStore.loadAll().first { $0.id == parsed.id }
        // A newer re-shared link updates the copy we have (see TimerPayload.shouldAdopt).
        let adoptLink = existing?.shouldAdopt(parsed) ?? false
        let stored = (adoptLink ? parsed : (existing ?? parsed)).advancedSequence()
        TimerStore.save(stored)
        // The full app may already own this id through AlarmKit (see
        // TimerStore.isAlarmKitArmed) — don't stack a second alert on top, unless the
        // link just changed the timing.
        if adoptLink || !TimerStore.isAlarmKitArmed(id: stored.id) {
            NotificationScheduler.cancel(id: stored.id)
            NotificationScheduler.scheduleAlert(for: stored)
        }
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
