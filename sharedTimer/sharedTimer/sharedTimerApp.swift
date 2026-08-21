//
//  sharedTimerApp.swift
//  sharedTimer
//

import SwiftUI

@main
struct sharedTimerApp: App {
    // First AppDelegate this project has needed — see AppDelegate.swift. Only used to
    // receive silent CloudKit push; nothing else in the app relies on it.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Horizon is dark-first by design — the skies hang in a dark room, and
                // on-sky text is always white. Pinning dark keeps system chrome (sheets,
                // forms, alerts) resolving against that world.
                .preferredColorScheme(.dark)
        }
    }
}
