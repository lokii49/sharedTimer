//
//  RecentTimersSync.swift
//  sharedTimer
//
//  Pushes RecentTimersStore out to the two system surfaces that show it: the
//  home-screen long-press Quick Actions (dynamic items, after the static New Timer /
//  New Countdown ones from Shortcuts.plist) and the Control Center / Action button
//  control (StartRecentTimerControl in the widget extension, whose title shows the
//  most recent timer). Call after anything that changes the recents.
//

import UIKit
import WidgetKit

enum RecentTimersSync {
    /// Quick Action type prefix; SceneDelegate/ContentView route "recent:<id>".
    static let quickActionPrefix = "recent:"
    static let controlKind = "StartRecentTimerControl"

    @MainActor
    static func refresh() {
        // The static items take two of the ~4 slots iOS shows; fill the rest.
        UIApplication.shared.shortcutItems = RecentTimersStore.all().prefix(2).map { recent in
            UIApplicationShortcutItem(
                type: quickActionPrefix + recent.id,
                localizedTitle: recent.label,
                localizedSubtitle: "Start \(RecentTimer.lengthText(recent.duration))",
                icon: UIApplicationShortcutIcon(systemImageName: "timer"),
                userInfo: nil
            )
        }
        ControlCenter.shared.reloadControls(ofKind: controlKind)
    }
}
