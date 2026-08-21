//
//  SceneDelegate.swift
//  sharedTimer
//
//  Exists solely to receive Home Screen Quick Action taps (long-press the app icon —
//  see sharedTimer/Shortcuts.plist for the static items and CLAUDE.md's plan for why this
//  needs a scene delegate rather than a SwiftUI modifier: once an app adopts scenes,
//  UIApplicationDelegate's older non-scene shortcut callback is never called). Bridges to
//  ContentView via NotificationCenter (warm launch) / pendingShortcutType (cold launch)
//  rather than a direct reference — ContentView has no existing handle to AppDelegate/
//  scene objects anywhere else in this codebase.
//

import UIKit

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // willConnectTo runs before ContentView's .onReceive subscriber exists on cold launch,
    // so posting straight to NotificationCenter here would drop silently. Buffer instead;
    // ContentView drains this in .onAppear.
    static var pendingShortcutType: String?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            Self.pendingShortcutType = shortcutItem.type
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        NotificationCenter.default.post(name: .quickActionTriggered, object: shortcutItem.type)
        completionHandler(true)
    }
}

extension Notification.Name {
    static let quickActionTriggered = Notification.Name("quickActionTriggered")
}
