//
//  TwoDeviceClashTests.swift
//  sharedTimerTests
//
//  Two phones on different iCloud accounts change one shared timer at the same moment,
//  against real CloudKit (development environment). Skipped unless a role is passed in
//  the environment (`TEST_RUNNER_CLASH_ROLE=…` on the xcodebuild command line):
//
//    setup   (owner phone)        creates the timer + a read-write share, prints its URL
//    join    (participant phone)  accepts that share (CLASH_SHARE_URL)
//    race    (both, together)     CLASH_TIMER_ID, CLASH_T0 (epoch s), CLASH_ACTION
//                                 (pause | extend), CLASH_ROUNDS, CLASH_RESET=1 on the owner
//    cleanup (both)               owner deletes the record; participant leaves
//
//  Each round: the owner resets the record to "running, 30 min left"; both read it;
//  at T the owner pauses and, 0.3 s later, the participant adds 5 min — each pushing from
//  the copy it read, as two people would. When a phone's save went through the conflict
//  merge, the newest stamp (the extend) must win whole: running, +5 min, "extended".
//

import CloudKit
import Foundation
import os
import Testing
@testable import sharedTimer

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLASH_ROLE"] != nil))
struct TwoDeviceClashTests {
    private let env = ProcessInfo.processInfo.environment
    private static let container = CKContainer(identifier: "iCloud.com.lokesh.sharedTimer")

    @Test func clash() async throws {
        switch env["CLASH_ROLE"] {
        case "setup": try await setup()
        case "join": try await join()
        case "race": try await race()
        case "cleanup": await cleanup()
        case "solo": try await solo()
        case "forced": try await forced()
        case "purge": await purge()
        default: Issue.record("unknown CLASH_ROLE")
        }
    }

    private func setup() async throws {
        await diagnose()
        let payload = TimerPayload(label: "Clash test", duration: 1800, alarmEnabled: false, vibrationEnabled: false)
        let url: URL? = await withCheckedContinuation { continuation in
            CloudSyncController.createShare(for: payload, timeout: 60) { continuation.resume(returning: $0) }
        }
        print("CLASH_SETUP url=\(url?.absoluteString ?? "nil") id=\(payload.id)")
        #expect(url != nil)
        #expect(CloudLinkStore.get(timerID: payload.id)?.isOwner == true)
    }

    private func join() async throws {
        await diagnose()
        let url = try #require(env["CLASH_SHARE_URL"].flatMap(URL.init(string:)))
        let accepted: TimerPayload? = await withCheckedContinuation { continuation in
            CloudSyncController.acceptShare(from: url) { continuation.resume(returning: $0) }
        }
        let link = accepted.flatMap { CloudLinkStore.get(timerID: $0.id) }
        print("CLASH_JOIN id=\(accepted?.id ?? "nil") participant=\(link.map { !$0.isOwner } ?? false) readOnly=\(accepted.map { TimerStore.isReadOnly(id: $0.id) } ?? true)")
        #expect(link?.isOwner == false)
    }

    private func race() async throws {
        let id = try #require(env["CLASH_TIMER_ID"])
        let t0 = try #require(env["CLASH_T0"].flatMap(Double.init))
        let action = try #require(env["CLASH_ACTION"])
        let rounds = Int(env["CLASH_ROUNDS"] ?? "") ?? 5
        let resets = env["CLASH_RESET"] == "1"
        let link = try #require(CloudLinkStore.get(timerID: id))
        for round in 0..<rounds {
            let t = Date(timeIntervalSince1970: t0 + Double(round) * 30)
            if resets {
                await sleep(until: t.addingTimeInterval(-12))
                let base = TimerPayload(id: id, label: "Clash test", endDate: t.addingTimeInterval(1800), duration: 1800,
                                        alarmEnabled: false, vibrationEnabled: false, updatedAt: t.addingTimeInterval(-12))
                await CloudSyncController.pushUpAwaiting(base, action: "updated")
            }
            await sleep(until: t.addingTimeInterval(-5))
            let local = try #require(await serverPayload(link), "round \(round): read before the clash")
            await sleep(until: action == "extend" ? t.addingTimeInterval(0.3) : t)
            let mine = action == "extend" ? local.extended(by: 300) : local.paused(at: Date())
            let before = CloudSyncController.conflictMerges.withLock { $0 }
            await CloudSyncController.pushUpAwaiting(mine, action: action == "extend" ? "extended" : "paused")
            let merged = CloudSyncController.conflictMerges.withLock { $0 } > before
            await sleep(until: t.addingTimeInterval(12))
            let (final, actor) = try #require(await serverState(link), "round \(round): read after the clash")
            let offset = Int((final.endDate.timeIntervalSince(t) - 1800).rounded())
            print("CLASH_ROUND \(round) role=\(action) merged=\(merged) paused=\(final.isPaused) endOffset=\(offset)s stamp=\(final.updatedAt?.timeIntervalSince(t) ?? .nan) last=\(actor?.action ?? "nil")")
            if merged {
                #expect(!final.isPaused, "round \(round): a merged clash must keep the newest change (the extend)")
                #expect(abs(offset - 300) <= 1, "round \(round): +5 min kept")
                #expect(actor?.action == "extended", "round \(round): attribution names the change that won")
            }
        }
    }

    /// One phone, real iCloud: each round both writes start at the same instant from the
    /// same fresh read (as two phones would), so one of them hits a real server conflict;
    /// over the rounds either may save first. The extend carries the newer stamp and must
    /// win whole whichever order the server saw.
    private func solo() async throws {
        await diagnose()
        let rounds = Int(env["CLASH_ROUNDS"] ?? "") ?? 6
        let seed = TimerPayload(label: "Clash test", duration: 1800, alarmEnabled: false, vibrationEnabled: false)
        let url: URL? = await withCheckedContinuation { continuation in
            CloudSyncController.createShare(for: seed, timeout: 60) { continuation.resume(returning: $0) }
        }
        let link = try #require(CloudLinkStore.get(timerID: seed.id), "record created (share url \(url?.absoluteString ?? "nil"))")
        var mergedRounds = 0
        for round in 0..<rounds {
            let t = Date().addingTimeInterval(8)
            let base = TimerPayload(id: seed.id, label: "Clash test", endDate: t.addingTimeInterval(1800), duration: 1800,
                                    alarmEnabled: false, vibrationEnabled: false, updatedAt: Date())
            await CloudSyncController.pushUpAwaiting(base, action: "updated")
            await sleep(until: t.addingTimeInterval(-3))
            let read = try #require(await serverPayload(link), "round \(round): fresh read")
            await sleep(until: t)
            let pause = read.paused(at: t)
            var extend = read.extended(by: 300)
            extend.updatedAt = t.addingTimeInterval(0.3)
            let before = CloudSyncController.conflictMerges.withLock { $0 }
            async let a: Void = CloudSyncController.pushUpAwaiting(pause, action: "paused")
            async let b: Void = CloudSyncController.pushUpAwaiting(extend, action: "extended")
            _ = await (a, b)
            let merges = CloudSyncController.conflictMerges.withLock { $0 } - before
            if merges > 0 { mergedRounds += 1 }
            let (final, actor) = try #require(await serverState(link), "round \(round): read after")
            let offset = Int((final.endDate.timeIntervalSince(t) - 1800).rounded())
            print("CLASH_SOLO round=\(round) merges=\(merges) paused=\(final.isPaused) endOffset=\(offset)s stamp=\(final.updatedAt.map { $0.timeIntervalSince(t) } ?? .nan) last=\(actor?.action ?? "nil")")
            if merges > 0 {
                #expect(!final.isPaused, "round \(round): the newest change (extend) wins a merged clash")
                #expect(abs(offset - 300) <= 1, "round \(round): +5 min kept")
                #expect(actor?.action == "extended", "round \(round): attribution names the change that won")
            }
        }
        // Informational: on one phone the two pushes ran one after the other (0 of 6
        // conflicted on 2026-11-27) and the last save won whole — see ROADMAP 1.0.9.
        print("CLASH_SOLO merged \(mergedRounds) of \(rounds) rounds")
        await purge()
    }

    /// A true conflict, forced: two copies of one fetched record saved one after the other
    /// with `.ifServerRecordUnchanged`, in both orders. Checks against the real server that
    /// the second save is refused with the first's record as `serverRecord` and the fetched
    /// copy as `ancestorRecord` (what `merged` assumes), and that the merged save keeps
    /// the newest change (the extend) whole.
    private func forced() async throws {
        await diagnose()
        let seed = TimerPayload(label: "Clash test", duration: 1800, alarmEnabled: false, vibrationEnabled: false)
        _ = await withCheckedContinuation { continuation in
            CloudSyncController.createShare(for: seed, timeout: 60) { continuation.resume(returning: $0) }
        }
        let link = try #require(CloudLinkStore.get(timerID: seed.id), "record created")
        let database = Self.container.privateCloudDatabase
        for pauseFirst in [true, false] {
            let t = Date()
            let base = TimerPayload(id: seed.id, label: "Clash test", endDate: t.addingTimeInterval(1800), duration: 1800,
                                    alarmEnabled: false, vibrationEnabled: false, updatedAt: t.addingTimeInterval(-1))
            await CloudSyncController.pushUpAwaiting(base, action: "updated")
            let fetched = try #require(await record(link))
            let read = try #require(CloudSyncController.makePayload(from: fetched))
            func copy(_ payload: TimerPayload, _ action: String) -> CKRecord {
                let record = fetched.copy() as! CKRecord
                CloudSyncController.applyFields(from: payload, to: record)
                record["lastAction"] = action as CKRecordValue
                return record
            }
            var extendPayload = read.extended(by: 300)
            extendPayload.updatedAt = t.addingTimeInterval(0.3)
            let pause = copy(read.paused(at: t), "paused"), extend = copy(extendPayload, "extended")
            let (first, second) = pauseFirst ? (pause, extend) : (extend, pause)
            let firstResult = try await database.modifyRecords(saving: [first], deleting: [], savePolicy: .ifServerRecordUnchanged).saveResults[first.recordID]
            if case .failure(let error) = firstResult { Issue.record("first save failed: \(error)") }
            let secondResult = try await database.modifyRecords(saving: [second], deleting: [], savePolicy: .ifServerRecordUnchanged).saveResults[second.recordID]
            guard case .failure(let error) = secondResult, let conflict = error as? CKError, conflict.code == .serverRecordChanged,
                  let server = conflict.serverRecord else {
                Issue.record("pauseFirst=\(pauseFirst): the second save was not refused as a conflict: \(String(describing: secondResult))")
                continue
            }
            let ancestorIsFetched = conflict.ancestorRecord?.recordChangeTag == fetched.recordChangeTag
            let merged = CloudSyncController.merged(client: second, ancestor: conflict.ancestorRecord, server: server)
            let mergedResult = try await database.modifyRecords(saving: [merged], deleting: [], savePolicy: .ifServerRecordUnchanged).saveResults[merged.recordID]
            if case .failure(let error) = mergedResult { Issue.record("merged save failed: \(error)") }
            let (final, actor) = try #require(await serverState(link))
            let offset = Int((final.endDate.timeIntervalSince(t) - 1800).rounded())
            print("CLASH_FORCED pauseFirst=\(pauseFirst) ancestorIsFetched=\(ancestorIsFetched) paused=\(final.isPaused) endOffset=\(offset)s last=\(actor?.action ?? "nil")")
            #expect(ancestorIsFetched, "CloudKit's ancestorRecord is the copy this device fetched")
            #expect(!final.isPaused && abs(offset - 300) <= 1, "pauseFirst=\(pauseFirst): the newer extend wins whole")
            #expect(actor?.action == "extended")
        }
        await purge()
    }

    /// Removes every "Clash test" timer this phone holds — records (awaited), links and
    /// stored copies — so nothing from these runs lingers in the person's app.
    private func purge() async {
        var removed = 0
        for link in CloudLinkStore.all().values where link.isOwner {
            guard let record = await record(link), record["label"] as? String == "Clash test" else { continue }
            _ = try? await Self.container.privateCloudDatabase.modifyRecords(saving: [], deleting: [record.recordID])
            CloudLinkStore.remove(timerID: link.timerID)
            removed += 1
        }
        for payload in TimerStore.loadAll() where payload.label == "Clash test" { TimerStore.delete(id: payload.id) }
        // A queued owner delete whose record still exists here as a test record: finish it.
        // Anything else in the queue is left alone (it may be one of the person's own).
        var finished = 0
        for link in CloudLinkStore.pendingDeletes() {
            guard let record = await record(link), record["label"] as? String == "Clash test" else { continue }
            _ = try? await Self.container.privateCloudDatabase.modifyRecords(saving: [], deleting: [record.recordID])
            CloudLinkStore.removePendingDelete(timerID: link.timerID)
            finished += 1
        }
        let left = TimerStore.loadAll().filter { $0.label == "Clash test" }.count
        print("CLASH_PURGE removed=\(removed) queuedFinished=\(finished) queued=\(CloudLinkStore.pendingDeletes().count) storedLeft=\(left)")
    }

    private func cleanup() async {
        guard let id = env["CLASH_TIMER_ID"] else { return }
        CloudSyncController.pushDelete(id: id)
        TimerStore.delete(id: id)
        try? await Task.sleep(for: .seconds(5))
        print("CLASH_CLEANUP id=\(id) linkLeft=\(CloudLinkStore.get(timerID: id) != nil)")
    }

    // MARK: helpers

    /// Account and zone state, so a failed run says why.
    private func diagnose() async {
        let status = try? await Self.container.accountStatus()
        print("CLASH_ACCOUNT status=\(status.map { String(describing: $0.rawValue) } ?? "error")")
        do {
            // Per-zone failures come back in the results, not as a throw.
            let (saved, _) = try await Self.container.privateCloudDatabase.modifyRecordZones(saving: [CKRecordZone(zoneName: "SharedTimers")], deleting: [])
            for (_, result) in saved {
                switch result {
                case .success: print("CLASH_ZONE ok")
                case .failure(let error): print("CLASH_ZONE error=\(error)")
                }
            }
        } catch {
            print("CLASH_ZONE error=\(error)")
        }
    }

    private func sleep(until date: Date) async {
        let wait = date.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    private func record(_ link: CloudLink) async -> CKRecord? {
        let database = link.isOwner ? Self.container.privateCloudDatabase : Self.container.sharedCloudDatabase
        let id = CKRecord.ID(recordName: link.recordName, zoneID: CKRecordZone.ID(zoneName: link.zoneName, ownerName: link.zoneOwnerName))
        return try? await database.record(for: id)
    }

    private func serverPayload(_ link: CloudLink) async -> TimerPayload? {
        await record(link).flatMap(CloudSyncController.makePayload(from:))
    }

    private func serverState(_ link: CloudLink) async -> (TimerPayload, (name: String, action: String)?)? {
        guard let record = await record(link), let payload = CloudSyncController.makePayload(from: record) else { return nil }
        return (payload, CloudSyncController.lastActor(from: record))
    }
}
