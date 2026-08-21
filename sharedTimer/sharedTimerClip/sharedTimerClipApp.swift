//
//  sharedTimerClipApp.swift
//  sharedTimerClip
//

import SwiftUI

@main
struct sharedTimerClipApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // See sharedTimerApp.swift — Horizon is dark-first by design.
                .preferredColorScheme(.dark)
        }
    }
}
