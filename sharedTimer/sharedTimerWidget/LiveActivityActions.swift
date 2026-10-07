//
//  LiveActivityActions.swift
//  sharedTimerWidget
//
//  No-op stub. Shared/LiveActivityIntents.swift is compiled into this target only so
//  the Live Activity views can build `Button(intent:)`s; the system always runs a
//  `LiveActivityIntent`'s `perform()` in the main app's process, where the real
//  LiveActivityActions (sharedTimer/LiveActivityActions.swift) lives. Never put logic
//  here — the widget must not reach AlarmController/CloudKit. Keep the signatures in
//  sync with the app's version or this target stops compiling.
//

import Foundation

enum LiveActivityActions {
    static func setPaused(timerID: String, paused: Bool) async {}
    static func stop(timerID: String) async {}
    static func advanceSequence(timerID: String, phaseIndex: Int) async {}
    static func endSequence(timerID: String) async {}
    static func repeatTimer(timerID: String) async {}
    static func startRecent(id: String) async {}
}
