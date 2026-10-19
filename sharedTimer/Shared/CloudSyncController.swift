//
//  CloudSyncController.swift
//  Shared
//
//  Live sync for shared timers, on top of the local TimerStore/App-Group model — see
//  CLAUDE.md's Phase 1 roadmap plan. One CKShare per timer, rooted at a custom "Timer"
//  CKRecord in a single custom zone ("SharedTimers") in the owner's private database.
//  `share.publicPermission = .readWrite` — anyone holding the link can accept and write,
//  no participant lookup, no sign-up beyond the iCloud login already on the device.
//
//  Two structural invariants a future edit must not violate:
//
//  1. NEVER call anything in this file from inside TimerStore.swift. TimerStore is
//     compiled into the Widget target, which must never touch the network from a
//     timeline-provider render pass. This file is compiled only into sharedTimer and
//     sharedTimerMessages — the two targets that actually mutate timers a person is
//     looking at.
//  2. Push-up is always an explicit, separate call at each mutation call site (see
//     ContentView.apply()/delete(), MessagesViewController.persist()) — the same pattern
//     NotificationScheduler/LiveActivityController already follow, never folded into
//     TimerStore.save() itself. If a receive-path write (pullChanges → TimerStore.save())
//     also triggered pushUp automatically, that would echo every remote change straight
//     back to the server. Keeping push-up structural, not automatic, prevents that loop.
//
//  A timer with no CloudLink entry is purely local — pre-CloudKit timers, timers that
//  were never shared, or timers whose share creation failed and fell back to a plain
//  link. Every function below treats that absence as a normal, silent no-op state, the
//  same way TimerPayload's own tolerant decode treats a missing `kind` as `.timer`.
//

import CloudKit
import Foundation

enum CloudSyncController {
    private static let appGroupID = "group.com.lokesh.sharedTimer"
    private static let zoneName = "SharedTimers"
    private static let subscriptionsRegisteredKey = "cloudSubscriptionsRegistered"
    private static let recordType = "Timer"

    /// Explicit, not `CKContainer.default()`. `.default()` resolves the container from
    /// the `com.apple.developer.icloud-container-identifiers` entitlement array at
    /// runtime — reliable in the main app, but observed failing inside the Messages
    /// extension's sandbox: it silently fell back to CloudKit's own undocumented
    /// last-resort default, `"iCloud." + bundle identifier`
    /// (`iCloud.com.lokesh.sharedTimer.sharedTimerMessages`, which doesn't exist as a
    /// real container — "Bad Container" (5/1014)), even with the entitlement correctly
    /// present in the source file, Xcode's Signing & Capabilities, and the container
    /// correctly enabled on the App ID in the Developer Portal. Naming it explicitly
    /// bypasses whatever that lookup is doing wrong in an extension context.
    private static let container = CKContainer(identifier: "iCloud.com.lokesh.sharedTimer")

    private static var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// The two CloudKit databases a device's timers can live in: this device's own
    /// private database (timers it created), or its shared database (timers it was
    /// invited into). `CKQuerySubscription` doesn't work on the shared database, so both
    /// sides of sync use the change-token-based database/zone APIs uniformly instead.
    private enum SyncScope: String, CaseIterable {
        case owner
        case participant

        var database: CKDatabase {
            switch self {
            case .owner: return CloudSyncController.container.privateCloudDatabase
            case .participant: return CloudSyncController.container.sharedCloudDatabase
            }
        }
    }

    // MARK: - Zone

    /// Always actually calls through to CloudKit — no local "already ensured" cache.
    /// `CKModifyRecordZonesOperation` saving a zone that already exists is a documented
    /// safe no-op, so the round trip this costs is cheap and reliable. A previous local
    /// cache (set once after the first success, keyed in App Group `UserDefaults`) went
    /// stale after `CKContainer.default()` was replaced with an explicit `container`
    /// (see its doc comment) — the flag had been set `true` against whatever container
    /// `.default()` resolved to at the time, then kept short-circuiting every later call
    /// even once the target container changed, producing "Zone Not Found" (26/2036)
    /// errors that looked like a fresh bug. Don't reintroduce caching here.
    static func ensureZoneExists(completion: @escaping (Bool) -> Void) {
        let zone = CKRecordZone(zoneName: zoneName)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
        operation.modifyRecordZonesResultBlock = { result in
            switch result {
            case .success:
                completion(true)
            case .failure(let error):
                log("ensureZoneExists failed: \(error)")
                completion(false)
            }
        }
        container.privateCloudDatabase.add(operation)
    }

    // MARK: - Push subscriptions (main app only — the Messages extension never receives push)

    /// Registers one silent `CKDatabaseSubscription` per database (private + shared).
    /// Main-app-only: called from `AppDelegate.didFinishLaunchingWithOptions`.
    /// `CKQuerySubscription` doesn't work on the shared database, which is why this is a
    /// database subscription rather than one scoped to the Timer record type.
    static func registerSubscriptionsIfNeeded() {
        if groupDefaults?.bool(forKey: subscriptionsRegisteredKey) == true { return }

        let group = DispatchGroup()
        var allOK = true
        for scope in SyncScope.allCases {
            group.enter()
            let subscription = CKDatabaseSubscription(subscriptionID: "sharedTimer.\(scope.rawValue)")
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo

            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
            operation.modifySubscriptionsResultBlock = { result in
                if case .failure(let error) = result {
                    log("registerSubscriptionsIfNeeded(\(scope.rawValue)) failed: \(error)")
                    allOK = false
                }
                group.leave()
            }
            scope.database.add(operation)
        }
        group.notify(queue: .main) {
            if allOK { groupDefaults?.set(true, forKey: subscriptionsRegisteredKey) }
        }
    }

    // MARK: - Create & share

    /// Creates the Timer record + CKShare and returns the share URL to send, or nil on
    /// any failure/timeout. Self-contained timeout (default 4s) — callers (the Messages
    /// compose flow) don't need their own race logic; on nil, send today's plain link.
    static func createShare(for payload: TimerPayload, timeout: TimeInterval = 4, completion: @escaping (URL?) -> Void) {
        var didComplete = false
        let completeOnce: (URL?) -> Void = { url in
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                completion(url)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            completeOnce(nil)
        }

        // Reuse a timer's existing share (owner or participant); CloudKit permits
        // only one share per root record. A failed lookup falls back to the snapshot.
        if let link = CloudLinkStore.get(timerID: payload.id) {
            // A cached URL answers at once; the fetch below still runs to refresh it.
            if let cached = CloudLinkStore.shareURL(timerID: payload.id) { completeOnce(cached) }
            fetchRecord(for: payload) { record, database in
                let zone = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
                let shareID = record?.share?.recordID ?? link.shareRecordName.map { CKRecord.ID(recordName: $0, zoneID: zone) }
                guard let shareID else { return completeOnce(nil) }
                database.fetch(withRecordID: shareID) { share, _ in
                    let url = (share as? CKShare)?.url
                    if let url { CloudLinkStore.setShareURL(url, timerID: payload.id) }
                    completeOnce(url)
                }
            }
            return
        }

        ensureZoneExists { ok in
            guard ok else { completeOnce(nil); return }

            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
            let recordID = CKRecord.ID(recordName: payload.id, zoneID: zoneID)
            let record = CKRecord(recordType: recordType, recordID: recordID)
            applyFields(from: payload, to: record)

            applyAttribution(action: "created", to: record)

            let share = CKShare(rootRecord: record)
            share.publicPermission = .readWrite
            share[CKShare.SystemFieldKey.title] = payload.label as CKRecordValue

            let operation = CKModifyRecordsOperation(recordsToSave: [record, share], recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            // `share.url` is nil on this local instance even after a successful save —
            // `modifyRecordsResultBlock` only reports overall success/failure, it never
            // updates the records you passed in. The server-assigned fields (including
            // the share URL) only exist on the record `perRecordSaveBlock` hands back.
            var savedShare: CKShare?
            var shareRecordError: Error?
            operation.perRecordSaveBlock = { recordID, result in
                guard recordID == share.recordID else { return }
                switch result {
                case .success(let saved):
                    savedShare = saved as? CKShare
                case .failure(let error):
                    // The overall operation can still report success even when the
                    // share record specifically failed to save (e.g. the root record
                    // already has a share — CloudKit allows only one per record) — this
                    // is the only place that per-record failure is visible. Captured
                    // rather than logged immediately so it survives into the nil-url
                    // message below instead of being overwritten by it (this callback
                    // fires before modifyRecordsResultBlock, and `log` only keeps the
                    // latest message for the on-screen diagnostic).
                    shareRecordError = error
                }
            }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    guard let url = savedShare?.url else {
                        if let shareRecordError {
                            log("createShare(\(payload.id)) share record save failed: \(shareRecordError)")
                        } else {
                            log("createShare(\(payload.id)) succeeded but share.url was nil")
                        }
                        completeOnce(nil)
                        return
                    }
                    // A participant who left and now shares the timer themselves owns this
                    // new share; the old "left" mark would make pullChanges drop it.
                    CloudLinkStore.clearLeft(timerID: payload.id)
                    CloudLinkStore.set(CloudLink(
                        timerID: payload.id,
                        recordName: payload.id,
                        zoneName: zoneName,
                        zoneOwnerName: CKCurrentUserDefaultName,
                        isOwner: true,
                        shareRecordName: share.recordID.recordName
                    ))
                    CloudLinkStore.setShareURL(url, timerID: payload.id)
                    // Newly shared: an open detail screen shows its Manage Sharing button.
                    DispatchQueue.main.async { NotificationCenter.default.post(name: sharingChanged, object: payload.id) }
                    completeOnce(url)
                case .failure(let error):
                    log("createShare(\(payload.id)) modifyRecords failed: \(error)")
                    completeOnce(nil)
                }
            }
            container.privateCloudDatabase.add(operation)
        }
    }

    // MARK: - Accept

    /// Called by the main app's `onOpenURL` and the Messages extension's bubble-open
    /// path when an incoming link carries a `ckshare` param. Accepts programmatically
    /// via CKFetchShareMetadataOperation +
    /// CKAcceptSharesOperation — never relies on the scene-delegate
    /// `userDidAcceptCloudKitShareWith` callback, since the raw icloud.com share URL is
    /// never the tappable link a recipient sees.
    static func acceptShare(from url: URL, completion: @escaping (TimerPayload?) -> Void) {
        let metadataOp = CKFetchShareMetadataOperation(shareURLs: [url])
        metadataOp.shouldFetchRootRecord = true
        // Set once a per-share result arrives; an operation that fails outright (no
        // account, offline) never reaches that block and must still call back.
        let lock = NSLock()
        var gotShareResult = false

        metadataOp.perShareMetadataResultBlock = { _, result in
            lock.lock(); gotShareResult = true; lock.unlock()
            guard case .success(let metadata) = result else {
                if case .failure(let error) = result {
                    log("acceptShare fetchMetadata failed: \(error)")
                }
                completion(nil)
                return
            }
            guard let rootRecord = metadata.rootRecord, let payload = makePayload(from: rootRecord) else {
                log("acceptShare metadata resolved but rootRecord was missing or unparseable")
                completion(nil)
                return
            }

            let zoneID = rootRecord.recordID.zoneID
            let link = CloudLink(
                timerID: payload.id,
                recordName: rootRecord.recordID.recordName,
                zoneName: zoneID.zoneName,
                zoneOwnerName: zoneID.ownerName,
                isOwner: metadata.participantRole == .owner,
                // Participants keep it too: a permission change arrives as this CKShare
                // record in zone changes, and this is how it maps back to the timer.
                shareRecordName: metadata.share.recordID.recordName
            )

            // The sharer re-opening their own link — already owns it, nothing to accept.
            guard metadata.participantRole != .owner else {
                CloudLinkStore.clearLeft(timerID: payload.id)
                CloudLinkStore.set(link)
                TimerStore.setReadOnly(id: payload.id, false)
                completion(payload)
                return
            }
            let readOnly = metadata.participantPermission == .readOnly

            let acceptOp = CKAcceptSharesOperation(shareMetadatas: [metadata])
            acceptOp.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    // Opening the link again is an explicit re-join.
                    CloudLinkStore.clearLeft(timerID: payload.id)
                    CloudLinkStore.set(link)
                    TimerStore.setReadOnly(id: payload.id, readOnly)
                    completion(payload)
                case .failure(let error):
                    log("acceptShare(\(payload.id)) CKAcceptSharesOperation failed: \(error)")
                    completion(nil)
                }
            }
            container.add(acceptOp)
        }
        metadataOp.fetchShareMetadataResultBlock = { result in
            if case .failure(let error) = result {
                log("acceptShare fetchShareMetadataResultBlock failed: \(error)")
            }
            lock.lock(); let handled = gotShareResult; lock.unlock()
            if !handled { completion(nil) }
        }
        container.add(metadataOp)
    }

    // MARK: - Push local mutations up

    /// Fire-and-forget. No-ops silently if this timer has no CloudLink (pure local
    /// timer). Retries once on a write conflict, reapplying only the fields this device
    /// changed onto the server's newer record (see `merged`).
    /// `action` is a short human-readable verb ("paused", "resumed", "extended") written
    /// alongside this device's DisplayNameStore name for the "who did what" surfaces.
    static func pushUp(_ payload: TimerPayload, action: String, completion: @escaping () -> Void = {}) {
        guard let link = CloudLinkStore.get(timerID: payload.id) else { return completion() }
        let scope: SyncScope = link.isOwner ? .owner : .participant
        let zoneID = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: link.recordName, zoneID: zoneID)
        let database = scope.database

        database.fetch(withRecordID: recordID) { record, error in
            // Record vanished server-side (e.g. owner deleted it elsewhere) — a future
            // pullChanges reconciles this locally; nothing to push to here.
            guard let record else {
                if let error { log("pushUp(\(payload.id)) fetch failed: \(error)") }
                completion()
                return
            }
            applyFields(from: payload, to: record)
            applyAttribution(action: action, to: record)
            save(record, to: database, retryOnConflict: true, completion: completion)
        }
    }

    /// Intents must keep the process alive through the fetch/save (including a conflict
    /// retry). Network failure remains best-effort, like other local timer mutations.
    static func pushUpAwaiting(_ payload: TimerPayload, action: String) async {
        await withCheckedContinuation { continuation in
            pushUp(payload, action: action) { continuation.resume() }
        }
    }

    private static func save(_ record: CKRecord, to database: CKDatabase, retryOnConflict: Bool, completion: @escaping () -> Void) {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        // `.changedKeys` never compares change tags, so it never reported a conflict
        // and the merge below never ran — every push overwrote every field. pushUp
        // always saves a just-fetched record, so this only trips on a real race.
        operation.savePolicy = .ifServerRecordUnchanged
        operation.modifyRecordsResultBlock = { result in
            guard case .failure(let error) = result else { return completion() }
            if isPermissionFailure(error, for: record.recordID) {
                // The owner made this share view-only since we last checked: CloudKit
                // refused the write. Stop offering changes here and put the server's
                // state back over the local edit.
                revertToServer(record.recordID, in: database)
                return completion()
            }
            guard retryOnConflict,
                  let conflict = serverRecordChangedError(from: error, for: record.recordID),
                  let serverRecord = conflict.serverRecord else {
                log("pushUp save(\(record.recordID.recordName)) failed, not retrying: \(error)")
                completion()
                return
            }
            let merged = merged(client: record, ancestor: conflict.ancestorRecord, server: serverRecord)
            save(merged, to: database, retryOnConflict: false, completion: completion)
        }
        database.add(operation)
    }

    /// Three-way merge for a write conflict: only the keys this device changed since
    /// its fetch (`ancestor`) go onto the server's newer record, so a concurrent change
    /// to another field (their extend, our pause) survives. A key cleared to nil counts
    /// as changed. Without an ancestor every local key wins, as before.
    static func merged(client: CKRecord, ancestor: CKRecord?, server: CKRecord) -> CKRecord {
        let keys = Set(client.allKeys()).union(client.changedKeys()).union(ancestor?.allKeys() ?? [])
        for key in keys {
            if let ancestor {
                let mine = client[key] as? NSObject
                let base = ancestor[key] as? NSObject
                guard mine != base else { continue }
            }
            server[key] = client[key]
        }
        return server
    }

    private static func isPermissionFailure(_ error: Error, for recordID: CKRecord.ID) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .permissionFailure { return true }
        return ckError.code == .partialFailure
            && (ckError.partialErrorsByItemID?[recordID] as? CKError)?.code == .permissionFailure
    }

    /// Posted on main with the server's copy (`object`) after a refused write was undone
    /// locally; the visible list/detail reload and re-arm from it.
    static let revertedToServer = Notification.Name("SharedTimerRevertedToServer")

    private static func revertToServer(_ recordID: CKRecord.ID, in database: CKDatabase) {
        guard let link = CloudLinkStore.all().values.first(where: { $0.recordName == recordID.recordName }) else { return }
        TimerStore.setReadOnly(id: link.timerID, true)
        database.fetch(withRecordID: recordID) { record, _ in
            guard let record, let payload = makePayload(from: record) else {
                // Couldn't read the server copy now: forget this zone's change token so
                // the next pull refetches every record in it, the refused edit included.
                clearToken(key: zoneTokenKey(recordID.zoneID))
                DispatchQueue.main.async { NotificationCenter.default.post(name: permissionsChanged, object: [link.timerID]) }
                return
            }
            DispatchQueue.main.async {
                // Store the server copy first, so the re-arm the permission change
                // triggers works from it, never from the refused edit.
                TimerStore.save(payload)
                NotificationCenter.default.post(name: revertedToServer, object: payload)
                NotificationCenter.default.post(name: permissionsChanged, object: [link.timerID])
            }
        }
    }

    /// Posted on main after a participant permission changed (zone changes, the
    /// explicit refresh, a refused write); `object` is the `[String]` of timer ids that
    /// changed. Screens re-read `TimerStore.isReadOnly`; the app re-arms just those.
    static let permissionsChanged = Notification.Name("SharedTimerPermissionsChanged")

    /// Posted on main when a timer became shared or stopped being shared on this phone
    /// (`object`: its id) — the Manage Sharing button and remove wording follow it, and
    /// the app re-arms it (a timer that left a view-only share gets its buttons back).
    static let sharingChanged = Notification.Name("SharedTimerSharingChanged")

    private static func applyPermission(_ permission: CKShare.ParticipantPermission, shareRecordName: String) {
        let readOnly = permission == .readOnly
        let links = CloudLinkStore.all().values.filter { !$0.isOwner && $0.shareRecordName == shareRecordName }
        var changed: [String] = []
        for link in links where TimerStore.isReadOnly(id: link.timerID) != readOnly {
            TimerStore.setReadOnly(id: link.timerID, readOnly)
            changed.append(link.timerID)
        }
        if !changed.isEmpty {
            DispatchQueue.main.async { NotificationCenter.default.post(name: permissionsChanged, object: changed) }
        }
    }

    /// Re-reads whether this device may change each timer shared with it — the owner can
    /// switch a share between "view only" and "can make changes" at any time in Manage
    /// Sharing. Participant links only; the owner can always write. Calls back on main.
    static func refreshPermissions(for timerIDs: [String]? = nil, completion: @escaping () -> Void = {}) {
        let links = CloudLinkStore.all().values.filter { !$0.isOwner && (timerIDs?.contains($0.timerID) ?? true) }
        guard !links.isEmpty else { return DispatchQueue.main.async(execute: completion) }
        let group = DispatchGroup()
        for link in links {
            group.enter()
            let zoneID = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
            let database = SyncScope.participant.database
            database.fetch(withRecordID: CKRecord.ID(recordName: link.recordName, zoneID: zoneID)) { record, _ in
                guard let shareID = record?.share?.recordID else { return group.leave() }
                // Links from before participants stored this get it now, so later
                // permission changes in zone changes can find their timer.
                if link.shareRecordName == nil {
                    CloudLinkStore.update(timerID: link.timerID) { current in
                        CloudLink(timerID: current.timerID, recordName: current.recordName, zoneName: current.zoneName,
                                  zoneOwnerName: current.zoneOwnerName, isOwner: current.isOwner,
                                  shareRecordName: current.shareRecordName ?? shareID.recordName)
                    }
                }
                database.fetch(withRecordID: shareID) { share, _ in
                    if let permission = (share as? CKShare)?.currentUserParticipant?.permission {
                        applyPermission(permission, shareRecordName: shareID.recordName)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    private static func serverRecordChangedError(from error: Error, for recordID: CKRecord.ID) -> CKError? {
        guard let ckError = error as? CKError else { return nil }
        if ckError.code == .serverRecordChanged { return ckError }
        if ckError.code == .partialFailure,
           let partial = ckError.partialErrorsByItemID?[recordID] as? CKError,
           partial.code == .serverRecordChanged {
            return partial
        }
        return nil
    }

    /// Owner delete removes the shared record — CloudKit cascades this to end the share
    /// for every participant. Participant delete never touches the shared record, only
    /// the local CloudLink — otherwise one recipient could destroy the timer for
    /// everyone. Either way the local CloudLink entry is dropped immediately; this
    /// doesn't wait on the network round trip.
    static func pushDelete(id: String) {
        guard let link = CloudLinkStore.get(timerID: id) else { return }
        defer { CloudLinkStore.remove(timerID: id) }
        guard link.isOwner else {
            CloudLinkStore.markLeft(timerID: id)
            return
        }

        let zoneID = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: link.recordName, zoneID: zoneID)
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [recordID])
        operation.modifyRecordsResultBlock = { result in
            if case .failure(let error) = result {
                log("pushDelete(\(id)) failed: \(error)")
            }
        }
        container.privateCloudDatabase.add(operation)
    }

    // MARK: - Pull remote changes down

    /// Main app only — called from the silent-push handler and from foreground-activate.
    /// Walks both databases via the change-token APIs (not CKQuerySubscription, which
    /// doesn't work on the shared database) so deletes are reported explicitly rather
    /// than inferred from a failed fetch.
    static func pullChanges(completion: @escaping (_ updated: [TimerPayload], _ deletedIDs: [String]) -> Void) {
        let group = DispatchGroup()
        var updated: [TimerPayload] = []
        var deletedIDs: [String] = []
        let lock = NSLock()

        for scope in SyncScope.allCases {
            group.enter()
            pullChanges(scope: scope) { u, d in
                lock.lock()
                updated.append(contentsOf: u)
                deletedIDs.append(contentsOf: d)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // A share this device left (participant delete) keeps reporting changes —
            // don't resurrect it. See CloudLinkStore.markLeft.
            completion(updated.filter { !CloudLinkStore.hasLeft(timerID: $0.id) }, deletedIDs)
        }
    }

    /// `isRetry` bounds the `.changeTokenExpired` recovery below to a single re-run.
    private static func pullChanges(scope: SyncScope, isRetry: Bool = false, completion: @escaping ([TimerPayload], [String]) -> Void) {
        let database = scope.database
        let tokenKey = "dbChangeToken.\(scope.rawValue)"

        let dbOp = CKFetchDatabaseChangesOperation(previousServerChangeToken: loadToken(key: tokenKey))
        var changedZoneIDs: [CKRecordZone.ID] = []
        var deletedZoneIDs: [CKRecordZone.ID] = []

        dbOp.recordZoneWithIDChangedBlock = { zoneID in changedZoneIDs.append(zoneID) }
        dbOp.recordZoneWithIDWasDeletedBlock = { zoneID in deletedZoneIDs.append(zoneID) }
        // Purged (the user removed the app's iCloud data) or wiped by an encrypted-data
        // reset: just as gone, and never reported as a plain deletion.
        dbOp.recordZoneWithIDWasPurgedBlock = { zoneID in deletedZoneIDs.append(zoneID) }
        dbOp.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { zoneID in deletedZoneIDs.append(zoneID) }
        // Deliberately no `changeTokenUpdatedBlock` save: the database token is only
        // persisted once every changed zone's records have actually been fetched (see
        // below). Saving it any earlier meant a failed zone fetch was never retried —
        // the next pull started *after* the change that named that zone, so those
        // records were silently skipped forever.
        dbOp.fetchDatabaseChangesResultBlock = { result in
            let databaseToken: CKServerChangeToken
            switch result {
            case .success(let value):
                databaseToken = value.serverChangeToken
            case .failure(let error):
                // An expired token fails every fetch that reuses it, so without this
                // reset live sync dies silently and permanently for this scope.
                if !isRetry, (error as? CKError)?.code == .changeTokenExpired {
                    log("pullChanges(\(scope.rawValue)) database token expired — refetching from scratch")
                    clearToken(key: tokenKey)
                    pullChanges(scope: scope, isRetry: true, completion: completion)
                    return
                }
                log("pullChanges(\(scope.rawValue)) fetchDatabaseChanges failed: \(error)")
                completion([], [])
                return
            }

            // A fully-deleted zone means every timer that lived in it is gone —
            // reconcile by scanning CloudLinkStore for any link pointing at that zone.
            var deletedIDs: [String] = []
            if !deletedZoneIDs.isEmpty {
                for (timerID, link) in CloudLinkStore.all()
                where deletedZoneIDs.contains(where: { $0.zoneName == link.zoneName && $0.ownerName == link.zoneOwnerName }) {
                    deletedIDs.append(timerID)
                    CloudLinkStore.remove(timerID: timerID)
                }
            }

            guard !changedZoneIDs.isEmpty else {
                saveToken(databaseToken, key: tokenKey)
                completion([], deletedIDs)
                return
            }
            fetchZoneChanges(changedZoneIDs, database: database) { updated, deleted, complete in
                if complete {
                    saveToken(databaseToken, key: tokenKey)
                }
                completion(updated, deletedIDs + deleted)
            }
        }
        database.add(dbOp)
    }

    /// `complete` is false when any zone's changes couldn't be fetched (other than the
    /// zone itself being gone) — the caller then keeps its old database token so the
    /// next pull reports those zones again. A zone whose own token expired is retried
    /// once immediately from a nil token, same recovery as the database level.
    private static func fetchZoneChanges(_ zoneIDs: [CKRecordZone.ID], database: CKDatabase, isRetry: Bool = false, completion: @escaping ([TimerPayload], [String], _ complete: Bool) -> Void) {
        var configs: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        for zoneID in zoneIDs {
            configs[zoneID] = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: loadToken(key: zoneTokenKey(zoneID))
            )
        }

        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIDs, configurationsByRecordZoneID: configs)
        var updated: [TimerPayload] = []
        var deletedIDs: [String] = []
        var expiredZoneIDs: [CKRecordZone.ID] = []
        // Zones where a record failed to download: their token must not move past it,
        // or that record is skipped until its next change.
        var failedZoneIDs: Set<CKRecordZone.ID> = []
        var complete = true

        operation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if let share = record as? CKShare {
                    // The owner switched "view only" / "can make changes" in Manage
                    // Sharing — apply it so open screens update without a restart.
                    if let permission = share.currentUserParticipant?.permission {
                        applyPermission(permission, shareRecordName: share.recordID.recordName)
                    }
                } else if let payload = makePayload(from: record) {
                    updated.append(payload)
                } else {
                    log("fetchZoneChanges: record \(recordID.recordName) fetched but unparseable")
                }
            case .failure(let error):
                log("fetchZoneChanges: record \(recordID.recordName) failed: \(error)")
                failedZoneIDs.insert(recordID.zoneID)
                complete = false
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedIDs.append(recordID.recordName)
        }
        operation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, _ in
            if let token, !failedZoneIDs.contains(zoneID) { saveToken(token, key: zoneTokenKey(zoneID)) }
        }
        operation.recordZoneFetchResultBlock = { zoneID, result in
            switch result {
            case .success(let value):
                if !failedZoneIDs.contains(zoneID) { saveToken(value.serverChangeToken, key: zoneTokenKey(zoneID)) }
            case .failure(let error):
                switch (error as? CKError)?.code {
                case .changeTokenExpired?:
                    clearToken(key: zoneTokenKey(zoneID))
                    expiredZoneIDs.append(zoneID)
                case .zoneNotFound?, .userDeletedZone?:
                    // Gone for good — nothing left to fetch, so this doesn't hold back
                    // the database token (that would refetch a dead zone forever).
                    break
                default:
                    complete = false
                }
                log("fetchZoneChanges: zone \(zoneID.zoneName) failed: \(error)")
            }
        }
        operation.fetchRecordZoneChangesResultBlock = { result in
            if case .failure(let error) = result {
                log("fetchZoneChanges overall failed: \(error)")
                // Per-zone failures can also surface here as an overall .partialFailure;
                // those were already classified in recordZoneFetchResultBlock (a dead
                // zone must not pin the database token), so only other errors count.
                if (error as? CKError)?.code != .partialFailure {
                    complete = false
                }
            }
            guard !expiredZoneIDs.isEmpty else {
                completion(updated, deletedIDs, complete)
                return
            }
            guard !isRetry else {
                completion(updated, deletedIDs, false)
                return
            }
            fetchZoneChanges(expiredZoneIDs, database: database, isRetry: true) { retryUpdated, retryDeleted, retryComplete in
                completion(updated + retryUpdated, deletedIDs + retryDeleted, complete && retryComplete)
            }
        }
        database.add(operation)
    }

    // MARK: - Payload <-> CKRecord

    static func applyFields(from payload: TimerPayload, to record: CKRecord) {
        record["label"] = payload.label as CKRecordValue
        record["endDate"] = payload.endDate as CKRecordValue
        record["duration"] = payload.duration as CKRecordValue
        record["pausedRemaining"] = payload.pausedRemaining as CKRecordValue?
        record["kind"] = payload.kind.rawValue as CKRecordValue
        record["alarmEnabled"] = payload.alarmEnabled as CKRecordValue
        record["vibrationEnabled"] = payload.vibrationEnabled as CKRecordValue
        record["recurrenceData"] = payload.recurrence.flatMap(AnnualRecurrence.encode) as CKRecordValue?
        record["sequenceData"] = payload.sequence.flatMap(TimerSequenceWire.encode) as CKRecordValue?
        record["scheduledStartDate"] = payload.scheduledStartDate as CKRecordValue?
        record["updatedAt"] = payload.updatedAt as CKRecordValue?
    }

    static func makePayload(from record: CKRecord) -> TimerPayload? {
        guard let label = record["label"] as? String,
              let endDate = record["endDate"] as? Date,
              let duration = record["duration"] as? TimeInterval,
              let kindRaw = record["kind"] as? String else { return nil }
        var sequence: SequenceInfo?
        if let value = record["sequenceData"] {
            guard let data = value as? Data, let decoded = TimerSequenceWire.decode(data) else { return nil }
            sequence = decoded
        }
        var recurrence: AnnualRecurrence?
        if let value = record["recurrenceData"] {
            guard kindRaw == "countdown", sequence == nil, let data = value as? Data,
                  let decoded = AnnualRecurrence.decode(data) else { return nil }
            recurrence = decoded
        }
        guard duration.isFinite, duration > 0, duration <= 1_000_000_000_000,
              endDate.timeIntervalSince1970.isFinite, abs(endDate.timeIntervalSince1970) <= 253_402_300_799 else { return nil }
        let paused = record["pausedRemaining"] as? TimeInterval
        guard paused.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000 }) ?? true else { return nil }
        return TimerPayload(
            id: record.recordID.recordName,
            label: label,
            endDate: endDate,
            duration: duration,
            pausedRemaining: record["pausedRemaining"] as? TimeInterval,
            kind: TimerKind(rawValue: kindRaw) ?? .timer,
            // Absent on records written before the toggle -> alarm on.
            alarmEnabled: (record["alarmEnabled"] as? Bool) ?? true,
            // Absent on records written before the toggle -> vibration OFF, not on —
            // see TimerModel.swift's matching decode for why (vibration-on now also
            // means a full-screen AlarmKit takeover).
            vibrationEnabled: (record["vibrationEnabled"] as? Bool) ?? false,
            sequence: sequence,
            scheduledStartDate: sequence == nil ? nil : record["scheduledStartDate"] as? Date,
            updatedAt: record["updatedAt"] as? Date, recurrence: recurrence
        ).alignedToCurrentPhase().advancedSequence()
    }

    // MARK: - Attribution

    /// Writes this device's self-declared name (DisplayNameStore) and the action that
    /// triggered this write onto the record. Deliberately not a TimerPayload field — see
    /// DisplayNameStore.swift and CloudLink.swift for why cloud-only identity stays off
    /// the wire format shared with docs/t.html.
    private static func applyAttribution(action: String, to record: CKRecord) {
        record["lastActorName"] = (DisplayNameStore.name ?? "Someone") as CKRecordValue
        record["lastAction"] = action as CKRecordValue
    }

    /// Reads back the attribution `applyAttribution` wrote, independent of building a
    /// TimerPayload. nil if the record predates this field (pre-Phase-2 timers).
    static func lastActor(from record: CKRecord) -> (name: String, action: String)? {
        guard let name = record["lastActorName"] as? String,
              let action = record["lastAction"] as? String else { return nil }
        return (name, action)
    }

    // MARK: - Participants & attribution (on-demand reads)

    /// Fetches this timer's current Timer record, if it has a CloudLink. Shared by
    /// fetchParticipantCount and fetchAttribution below so a caller wanting both (e.g. a
    /// detail view's .onAppear) only needs one round trip. Always calls back on main —
    /// every caller here feeds SwiftUI @State directly, unlike pushUp/pullChanges'
    /// background-queue callers, which hop to main themselves at their own call sites.
    private static func fetchRecord(for payload: TimerPayload, completion: @escaping (CKRecord?, CKDatabase) -> Void) {
        guard let link = CloudLinkStore.get(timerID: payload.id) else {
            DispatchQueue.main.async { completion(nil, container.privateCloudDatabase) }
            return
        }
        let scope: SyncScope = link.isOwner ? .owner : .participant
        let zoneID = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: link.recordName, zoneID: zoneID)
        let database = scope.database
        database.fetch(withRecordID: recordID) { record, error in
            if let error { log("fetchRecord(\(payload.id)) failed: \(error)") }
            DispatchQueue.main.async { completion(record, database) }
        }
    }

    /// Number of people on this timer's CKShare (owner + everyone who has accepted the
    /// link), or nil if this timer has no CloudLink or the share can't be resolved.
    /// On-demand only — no polling, matches every other CloudKit call in this file.
    /// Calls back on main (see fetchRecord).
    static func fetchParticipantCount(for payload: TimerPayload, completion: @escaping (Int?) -> Void) {
        fetchRecord(for: payload) { record, database in
            guard let shareRecordID = record?.share?.recordID else { completion(nil); return }
            database.fetch(withRecordID: shareRecordID) { shareRecord, shareError in
                guard let share = shareRecord as? CKShare else {
                    if let shareError { log("fetchParticipantCount(\(payload.id)) share fetch failed: \(shareError)") }
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.async { completion(share.participants.count) }
            }
        }
    }

    /// This timer's CKShare plus the container, for `UICloudSharingController` (Manage
    /// Sharing). Nil if the timer isn't shared or the share can't be fetched. Main queue.
    static func fetchShare(for payload: TimerPayload, completion: @escaping ((CKShare, CKContainer)?) -> Void) {
        fetchRecord(for: payload) { record, database in
            guard let shareRecordID = record?.share?.recordID else { completion(nil); return }
            database.fetch(withRecordID: shareRecordID) { shareRecord, error in
                if let error { log("fetchShare(\(payload.id)) failed: \(error)") }
                DispatchQueue.main.async { completion((shareRecord as? CKShare).map { ($0, container) }) }
            }
        }
    }

    /// After the owner stops sharing (or a participant removes themselves) in Manage
    /// Sharing: the timer stays on this device as a plain local timer. The owner's next
    /// Share creates a fresh record + share; a participant is marked as having left so
    /// later changes from the old share don't bring it back.
    static func didStopSharing(timerID: String) {
        let wasOwner = CloudLinkStore.get(timerID: timerID)?.isOwner ?? true
        CloudLinkStore.remove(timerID: timerID)
        if !wasOwner { CloudLinkStore.markLeft(timerID: timerID) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: sharingChanged, object: timerID) }
    }

    /// Who last touched this timer and what they did, or nil if there's no CloudLink or
    /// the record predates this field. On-demand only, same as fetchParticipantCount.
    /// Calls back on main (see fetchRecord).
    static func fetchAttribution(for payload: TimerPayload, completion: @escaping ((name: String, action: String)?) -> Void) {
        fetchRecord(for: payload) { record, _ in
            completion(record.flatMap(lastActor(from:)))
        }
    }

    // MARK: - Change tokens

    /// CKServerChangeToken is NSSecureCoding, not Codable — archived as Data into the
    /// same App Group suite TimerStore/CloudLinkStore already use.
    private static func zoneTokenKey(_ zoneID: CKRecordZone.ID) -> String {
        "zoneChangeToken.\(zoneID.ownerName).\(zoneID.zoneName)"
    }

    private static func loadToken(key: String) -> CKServerChangeToken? {
        guard let data = groupDefaults?.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func saveToken(_ token: CKServerChangeToken, key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        groupDefaults?.set(data, forKey: key)
    }

    private static func clearToken(key: String) {
        groupDefaults?.removeObject(forKey: key)
    }

    // MARK: - Logging

    /// Every failure path above logs through here instead of silently no-oping. This is
    /// the only diagnostic surface CloudKit failures have — Xcode's own console is the
    /// only place to see it, so when live sync doesn't work, filter the console on
    /// "CloudSync:" first.
    private static func log(_ message: String) {
        print("CloudSync: \(message)")
    }
}
