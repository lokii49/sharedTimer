//
//  sharedTimerWatchApp.swift
//  sharedTimerWatch Watch App
//
//  Created by Lokesh Pudhari on 21/08/26.
//

import SwiftUI

@main
struct sharedTimerWatch_Watch_AppApp: App {
    init() {
        WatchSyncController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
