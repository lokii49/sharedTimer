//
//  CloudLink.swift
//  sharedTimerMessages
//
//  Maps a local `TimerPayload.id` to the CloudKit record/zone it's backed by, when that
//  timer is cloud-synced. Deliberately NOT a field on `TimerPayload` — the payload's
//  `.url()`/`.from(url:)` wire format (App Clip, docs/t.html, plain iMessage links) must
//  stay small and unchanged, so cloud identity lives in its own local-only table instead.
//
//  A timer with no entry here is purely local — pre-CloudKit timers, or ones that were
//  never shared, or ones whose share creation failed and fell back to a plain link. That
//  absence is a normal, handled state everywhere this is read (see CloudSyncController),
//  the same way `TimerPayload`'s own tolerant decode treats a missing `kind` as `.timer`.
//
//  Duplicated verbatim into every target that needs it (sharedTimer, sharedTimerMessages)
//  — see CLAUDE.md. Not present in sharedTimerClip or sharedTimerWidget: neither target
//  ever resolves a timer's cloud identity.
//

import Foundation

/// Where a single timer's CloudKit record lives, and whether this device owns it.
struct CloudLink: Codable {
    /// == TimerPayload.id.
    let timerID: String
    /// CKRecord.ID.recordName of the Timer record (same string as `timerID` by
    /// construction — kept as its own field so the CloudKit-facing code never assumes
    /// that equality holds, in case a future record type needs a different name).
    let recordName: String
    /// The custom zone's name ("SharedTimers").
    let zoneName: String
    /// The zone's owner: "__defaultOwner__" when this device owns the timer, or the
    /// sharer's opaque CKRecordZone.ID.ownerName when this device is a participant
    /// reading from its own sharedCloudDatabase.
    let zoneOwnerName: String
    /// True if this device created the timer (writes go to privateCloudDatabase and this
    /// device may delete the record for everyone). False if this device accepted a share
    /// (writes go to sharedCloudDatabase; deleting only removes the local copy — see
    /// CloudSyncController.pushDelete).
    let isOwner: Bool
    /// The CKShare's own record name, owner side only — lets the owner re-derive
    /// `share.url` later (e.g. to reshare) without a network round trip. Participants
    /// don't need this, since they only ever look up the Timer record itself.
    let shareRecordName: String?
}

/// Local-only store for every timer's `CloudLink`, keyed by `timerID`. Same App Group
/// suite `TimerStore` uses, different key — this table is never synced itself, only
/// consulted to know WHERE to sync a given timer.
enum CloudLinkStore {
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let key = "cloudLinks"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func get(timerID: String) -> CloudLink? {
        all()[timerID]
    }

    static func set(_ link: CloudLink) {
        var links = all()
        links[link.timerID] = link
        persist(links)
    }

    static func remove(timerID: String) {
        var links = all()
        links.removeValue(forKey: timerID)
        persist(links)
    }

    static func all() -> [String: CloudLink] {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CloudLink].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ links: [String: CloudLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults?.set(data, forKey: key)
    }
}
