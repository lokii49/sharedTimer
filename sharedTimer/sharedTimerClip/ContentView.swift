//
//  ContentView.swift
//  sharedTimerClip
//

import SwiftUI
import StoreKit

struct ContentView: View {
    @State private var payload: TimerPayload?
    /// The "get the full app" banner, until dismissed; held back while a timer rings
    /// (it sits over the Stop button).
    @State private var wantsAppOverlay = true
    @ObservedObject private var alarm = AlarmPlayer.shared
    @ObservedObject private var vibration = VibrationPlayer.shared

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
        .onReceive(NotificationCenter.default.publisher(for: ClipNotificationDelegate.opened)) { note in
            if let id = note.object as? String { show(storedID: id) }
        }
        .onAppear {
            // Launched without a link (a tapped notification, the App Library): show a
            // timer this Clip already holds rather than the empty state. A link arriving
            // just after still wins — `handle` replaces it.
            if payload == nil {
                if let id = ClipNotificationDelegate.pendingTimerID { show(storedID: id) }
                else { payload = Self.mostRelevant(TimerStore.loadAll()) }
            }
        }
        // The system's own overlay: it waits for the scene itself (the old manual
        // `SKOverlay.present`, run from `.task`, found no active scene on a cold launch
        // and never retried).
        .appStoreOverlay(isPresented: Binding(
            get: { wantsAppOverlay && !(alarm.isPlaying || vibration.isVibrating) },
            set: { if !$0 && !(alarm.isPlaying || vibration.isVibrating) { wantsAppOverlay = false } }
        )) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    private func show(storedID id: String) {
        ClipNotificationDelegate.pendingTimerID = nil
        if let stored = TimerStore.loadAll().first(where: { $0.id == id }) { payload = stored.advancedSequence() }
    }

    /// With no link: a timer that finished within the hour (the notification someone
    /// just tapped), else the soonest running one, else the latest stored.
    static func mostRelevant(_ stored: [TimerPayload], at date: Date = Date()) -> TimerPayload? {
        let current = stored.map { $0.advancedSequence(at: date) }
        if let justFinished = current.filter({ $0.isExpired && $0.endDate > date.addingTimeInterval(-3600) }).max(by: { $0.endDate < $1.endDate }) {
            return justFinished
        }
        if let running = current.filter({ !$0.isExpired && !$0.isPaused }).min(by: { $0.endDate < $1.endDate }) { return running }
        return current.max(by: { $0.endDate < $1.endDate })
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

}

#Preview {
    ContentView()
}
