//
//  CloudSyncController.swift
//  sharedTimer
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
//     duplicated into the Widget target, which must never touch the network from a
//     timeline-provider render pass. This file is duplicated only into sharedTimer and
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
            guard !didComplete else { return }
            didComplete = true
            completion(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !didComplete {
                log("createShare(\(payload.id)) timed out after \(timeout)s")
            }
            completeOnce(nil)
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
                    CloudLinkStore.set(CloudLink(
                        timerID: payload.id,
                        recordName: payload.id,
                        zoneName: zoneName,
                        zoneOwnerName: CKCurrentUserDefaultName,
                        isOwner: true,
                        shareRecordName: share.recordID.recordName
                    ))
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

    /// Main app only, called from `onOpenURL` when an incoming link carries a `ckshare`
    /// param. Accepts programmatically via CKFetchShareMetadataOperation +
    /// CKAcceptSharesOperation — never relies on the scene-delegate
    /// `userDidAcceptCloudKitShareWith` callback, since the raw icloud.com share URL is
    /// never the tappable link a recipient sees.
    static func acceptShare(from url: URL, completion: @escaping (TimerPayload?) -> Void) {
        let metadataOp = CKFetchShareMetadataOperation(shareURLs: [url])
        metadataOp.shouldFetchRootRecord = true

        metadataOp.perShareMetadataResultBlock = { _, result in
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
                shareRecordName: nil
            )

            // The sharer re-opening their own link — already owns it, nothing to accept.
            guard metadata.participantRole != .owner else {
                CloudLinkStore.set(link)
                completion(payload)
                return
            }

            let acceptOp = CKAcceptSharesOperation(shareMetadatas: [metadata])
            acceptOp.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    CloudLinkStore.set(link)
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
        }
        container.add(metadataOp)
    }

    // MARK: - Push local mutations up

    /// Fire-and-forget. No-ops silently if this timer has no CloudLink (pure local
    /// timer). Retries once on a write conflict, taking the server record and reapplying
    /// this device's field values on top — last-writer-wins on endDate/pausedRemaining.
    /// `action` is a short human-readable verb ("paused", "resumed", "extended") written
    /// alongside this device's DisplayNameStore name for the "who did what" surfaces.
    static func pushUp(_ payload: TimerPayload, action: String) {
        guard let link = CloudLinkStore.get(timerID: payload.id) else { return }
        let scope: SyncScope = link.isOwner ? .owner : .participant
        let zoneID = CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName)
        let recordID = CKRecord.ID(recordName: link.recordName, zoneID: zoneID)
        let database = scope.database

        database.fetch(withRecordID: recordID) { record, error in
            // Record vanished server-side (e.g. owner deleted it elsewhere) — a future
            // pullChanges reconciles this locally; nothing to push to here.
            guard let record else {
                if let error { log("pushUp(\(payload.id)) fetch failed: \(error)") }
                return
            }
            applyFields(from: payload, to: record)
            applyAttribution(action: action, to: record)
            save(record, to: database, retryOnConflict: true)
        }
    }

    private static func save(_ record: CKRecord, to database: CKDatabase, retryOnConflict: Bool) {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.modifyRecordsResultBlock = { result in
            guard case .failure(let error) = result else { return }
            guard retryOnConflict,
                  let conflict = serverRecordChangedError(from: error, for: record.recordID),
                  let serverRecord = conflict.serverRecord else {
                log("pushUp save(\(record.recordID.recordName)) failed, not retrying: \(error)")
                return
            }
            for key in record.allKeys() {
                serverRecord[key] = record[key]
            }
            save(serverRecord, to: database, retryOnConflict: false)
        }
        database.add(operation)
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
        guard link.isOwner else { return }

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
            completion(updated, deletedIDs)
        }
    }

    private static func pullChanges(scope: SyncScope, completion: @escaping ([TimerPayload], [String]) -> Void) {
        let database = scope.database
        let tokenKey = "dbChangeToken.\(scope.rawValue)"

        let dbOp = CKFetchDatabaseChangesOperation(previousServerChangeToken: loadToken(key: tokenKey))
        var changedZoneIDs: [CKRecordZone.ID] = []
        var deletedZoneIDs: [CKRecordZone.ID] = []

        dbOp.recordZoneWithIDChangedBlock = { zoneID in changedZoneIDs.append(zoneID) }
        dbOp.recordZoneWithIDWasDeletedBlock = { zoneID in deletedZoneIDs.append(zoneID) }
        dbOp.changeTokenUpdatedBlock = { token in saveToken(token, key: tokenKey) }
        dbOp.fetchDatabaseChangesResultBlock = { result in
            switch result {
            case .success(let value):
                saveToken(value.serverChangeToken, key: tokenKey)
            case .failure(let error):
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
                completion([], deletedIDs)
                return
            }
            fetchZoneChanges(changedZoneIDs, database: database) { updated, deleted in
                completion(updated, deletedIDs + deleted)
            }
        }
        database.add(dbOp)
    }

    private static func fetchZoneChanges(_ zoneIDs: [CKRecordZone.ID], database: CKDatabase, completion: @escaping ([TimerPayload], [String]) -> Void) {
        var configs: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration] = [:]
        for zoneID in zoneIDs {
            configs[zoneID] = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                previousServerChangeToken: loadToken(key: zoneTokenKey(zoneID))
            )
        }

        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: zoneIDs, configurationsByRecordZoneID: configs)
        var updated: [TimerPayload] = []
        var deletedIDs: [String] = []

        operation.recordWasChangedBlock = { recordID, result in
            switch result {
            case .success(let record):
                if let payload = makePayload(from: record) {
                    updated.append(payload)
                } else {
                    log("fetchZoneChanges: record \(recordID.recordName) fetched but unparseable")
                }
            case .failure(let error):
                log("fetchZoneChanges: record \(recordID.recordName) failed: \(error)")
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedIDs.append(recordID.recordName)
        }
        operation.recordZoneChangeTokensUpdatedBlock = { zoneID, token, _ in
            if let token { saveToken(token, key: zoneTokenKey(zoneID)) }
        }
        operation.recordZoneFetchResultBlock = { zoneID, result in
            if case .success(let value) = result {
                saveToken(value.serverChangeToken, key: zoneTokenKey(zoneID))
            }
        }
        operation.fetchRecordZoneChangesResultBlock = { result in
            if case .failure(let error) = result {
                log("fetchZoneChanges overall failed: \(error)")
            }
            completion(updated, deletedIDs)
        }
        database.add(operation)
    }

    // MARK: - Payload <-> CKRecord

    private static func applyFields(from payload: TimerPayload, to record: CKRecord) {
        record["label"] = payload.label as CKRecordValue
        record["endDate"] = payload.endDate as CKRecordValue
        record["duration"] = payload.duration as CKRecordValue
        record["pausedRemaining"] = payload.pausedRemaining as CKRecordValue?
        record["kind"] = payload.kind.rawValue as CKRecordValue
        record["alarmEnabled"] = payload.alarmEnabled as CKRecordValue
        record["vibrationEnabled"] = payload.vibrationEnabled as CKRecordValue
    }

    private static func makePayload(from record: CKRecord) -> TimerPayload? {
        guard let label = record["label"] as? String,
              let endDate = record["endDate"] as? Date,
              let duration = record["duration"] as? TimeInterval,
              let kindRaw = record["kind"] as? String else { return nil }
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
            vibrationEnabled: (record["vibrationEnabled"] as? Bool) ?? false
        )
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

    // MARK: - Logging

    /// Every failure path above logs through here instead of silently no-oping. This is
    /// the only diagnostic surface CloudKit failures have — Xcode's own console is the
    /// only place to see it, so when live sync doesn't work, filter the console on
    /// "CloudSync:" first.
    private static func log(_ message: String) {
        print("CloudSync: \(message)")
    }
}
