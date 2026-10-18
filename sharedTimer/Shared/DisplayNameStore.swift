//
//  DisplayNameStore.swift
//  Shared
//
//  Self-declared display name for CloudKit attribution — see CLAUDE.md's Phase 2 plan.
//  CKShare accepted via a public .readWrite link never returns participant
//  nameComponents (Apple withholds identity for anonymous link-based accepts), so
//  attribution ("Sam paused Pasta") has no other name source. This name rides the
//  CKRecord itself (CloudSyncController.applyFields), never TimerPayload — same
//  reasoning CloudLink.swift documents for keeping cloud identity out of the wire
//  format shared with docs/t.html.
//
//  Lives in Shared/, compiled by sharedTimer and sharedTimerMessages — the two targets that
//  mutate shared timers. Not present in sharedTimerClip or sharedTimerWidget.
//

import Foundation

enum DisplayNameStore {
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "displayName"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// nil means the person has never been asked (or skipped the prompt) — callers fall
    /// back to a generic label rather than treating this as an error state.
    static var name: String? {
        get { defaults?.string(forKey: key) }
        set { defaults?.set(newValue, forKey: key) }
    }

    private static let declinedKey = "displayNameDeclined"

    /// Set when someone taps Skip, so the prompt doesn't come back on every share or
    /// mutation. A name can still be set (or cleared) any time in Settings.
    static var declined: Bool {
        get { defaults?.bool(forKey: declinedKey) ?? false }
        set { defaults?.set(newValue, forKey: declinedKey) }
    }

    /// Whether to show the "What should we call you?" prompt at all.
    static var shouldPrompt: Bool { name == nil && !declined }
}
