//
//  SyncBaseTests.swift
//  sharedTimerTests
//
//  N15: a push made from a stale copy must not overwrite a newer change on the server.
//  `CloudSyncController.plannedPush` decides what goes up against the sync base (the
//  server copy this device last saw); `changedFields` decides what counts as a change.
//

import CloudKit
import Foundation
import os
import Testing
@testable import sharedTimer

struct SyncBaseTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ payload: TimerPayload, actor: String? = nil, action: String? = nil) -> CKRecord {
        let record = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: payload.id))
        CloudSyncController.applyFields(from: payload, to: record)
        if let actor { record["lastActorName"] = actor as CKRecordValue }
        if let action { record["lastAction"] = action as CKRecordValue }
        return record
    }

    /// A running 10-minute timer, last changed at `t0`.
    private func running() -> TimerPayload {
        var payload = TimerPayload.compose(label: "Pasta", kind: .timer, minutes: 10, targetDate: t0)
        payload.endDate = t0.addingTimeInterval(600)
        payload.updatedAt = t0
        return payload
    }

    @Test func anUntouchedTimerIsNoChangeThroughStoreJSONAndAnArchivedRecord() throws {
        let now = t0.addingTimeInterval(90)
        var sequence = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)], loopCount: 3)
        sequence.endDate = t0.addingTimeInterval(60.123456)
        let annual = TimerPayload.composeAnnual(label: "Birthday", targetDate: t0.addingTimeInterval(86_400 * 40), timeZone: .gmt, at: t0)
        let daily = TimerPayload.composeAnnual(label: "Pills", targetDate: t0.addingTimeInterval(3_600), timeZone: .gmt, frequency: .daily, at: t0)
        let weekly = TimerPayload.composeAnnual(label: "Gym", targetDate: t0.addingTimeInterval(86_400 * 3), timeZone: TimeZone(identifier: "Asia/Kolkata")!, frequency: .weekly, at: t0)
        let pausedSequence = sequence.paused(at: t0.addingTimeInterval(20))
        for payload in [running(), running().paused(at: t0.addingTimeInterval(30)), sequence, pausedSequence, annual, daily, weekly] {
            // What the store keeps…
            let stored = try JSONDecoder().decode(TimerPayload.self, from: JSONEncoder().encode(payload))
            // …and what the base keeps: an archived record, its dates cut to milliseconds
            // as CloudKit does.
            let original = record(payload)
            for key in ["endDate", "scheduledStartDate", "updatedAt"] {
                if let date = original[key] as? Date {
                    original[key] = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000) as CKRecordValue
                }
            }
            let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: true)
            let archived = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
            let base = try #require(CloudSyncController.makePayload(from: archived))
            #expect(CloudSyncController.changedFields(from: base, to: stored, at: now).isEmpty, "\(payload.label)")
            // An untouched push sends nothing.
            #expect(CloudSyncController.plannedPush(local: stored, action: "updated", server: record(payload), base: archived, at: now).record == nil)
        }
    }

    @Test func aSequenceMovingOnByTheClockIsNoOnesChange() {
        var stored = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)], loopCount: 3)
        stored.endDate = t0.addingTimeInterval(60)
        let later = t0.addingTimeInterval(170)
        // One copy re-derived (phase 1 of loop 2, new label/end), the other still stored at phase 0.
        let advanced = stored.advancedSequence(at: later)
        #expect(advanced.label != stored.label)
        #expect(CloudSyncController.changedFields(from: advanced, to: stored, at: later).isEmpty)
    }

    @Test func aStalePauseDoesNotOverwriteANewerExtend() throws {
        let base = running()
        // This phone paused at +30 s but was offline; another phone extended at +60 s.
        let stalePause = base.paused(at: t0.addingTimeInterval(30))
        var extended = base.extended(by: 300)
        extended.updatedAt = t0.addingTimeInterval(60)
        let server = record(extended, actor: "Sam", action: "extended")
        let plan = CloudSyncController.plannedPush(local: stalePause, action: "paused", server: server, base: record(base))
        // Nothing of ours survives: send nothing; this phone takes the server's copy.
        #expect(plan.record == nil)
        let settled = CloudSyncController.settlement(pushed: stalePause, stored: stalePause, serverNow: extended, at: t0.addingTimeInterval(61))
        #expect(settled == .init(storeBase: true, replaceStored: true))
    }

    @Test func aNewerPauseWinsOverAnOlderExtend() throws {
        let base = running()
        var extended = base.extended(by: 300)
        extended.updatedAt = t0.addingTimeInterval(60)
        let pause = base.paused(at: t0.addingTimeInterval(90))
        let plan = CloudSyncController.plannedPush(local: pause, action: "paused", server: record(extended, actor: "Sam", action: "extended"), base: record(base))
        let sent = try #require(plan.record)
        let result = try #require(CloudSyncController.makePayload(from: sent))
        #expect(result.isPaused)
        #expect(result.endDate == pause.endDate)
        #expect(sent["lastAction"] as? String == "paused")
        #expect(sent["updatedAt"] as? Date == pause.updatedAt)
    }

    @Test func aRenameElsewhereSurvivesAPauseHere() throws {
        let base = running()
        // Renamed elsewhere *after* this phone's pause: the server's stamp is newer, but
        // its timing never moved, so this pause isn't a conflict and still goes up.
        var renamed = base
        renamed.label = "Tea"
        renamed.updatedAt = t0.addingTimeInterval(60)
        let pause = base.paused(at: t0.addingTimeInterval(30))
        let plan = CloudSyncController.plannedPush(local: pause, action: "paused", server: record(renamed, actor: "Sam", action: "edited"), base: record(base))
        let sent = try #require(plan.record)
        let result = try #require(CloudSyncController.makePayload(from: sent))
        #expect(result.isPaused)
        #expect(result.label == "Tea")
        #expect(sent["updatedAt"] as? Date == renamed.updatedAt)
        #expect(sent["lastAction"] as? String == "paused" && sent["lastActorName"] as? String != "Sam")
        // This phone takes the rename.
        #expect(CloudSyncController.settlement(pushed: pause, stored: pause, serverNow: result, at: t0.addingTimeInterval(61)).replaceStored)
    }

    @Test func aRenameHereKeepsTheirNewerExtendAndTheirAttribution() throws {
        let base = running()
        var extended = base.extended(by: 300)
        extended.updatedAt = t0.addingTimeInterval(60)
        var renamed = base
        renamed.label = "Tea"
        renamed.updatedAt = t0.addingTimeInterval(30)
        let plan = CloudSyncController.plannedPush(local: renamed, action: "edited", server: record(extended, actor: "Sam", action: "extended"), base: record(base))
        let sent = try #require(plan.record)
        let result = try #require(CloudSyncController.makePayload(from: sent))
        #expect(result.label == "Tea")
        #expect(result.endDate == extended.endDate)
        // All of our change went up, so it is ours to name.
        #expect(sent["lastAction"] as? String == "edited")
        #expect(sent["updatedAt"] as? Date == extended.updatedAt)
    }

    @Test func withoutABaseEveryLocalFieldGoesUpAsBefore() throws {
        let base = running()
        var extended = base.extended(by: 300)
        extended.updatedAt = t0.addingTimeInterval(60)
        let stalePause = base.paused(at: t0.addingTimeInterval(30))
        for missing in [nil, record(TimerPayload.compose(label: "Other", kind: .timer, minutes: 1, targetDate: t0))] {
            let plan = CloudSyncController.plannedPush(local: stalePause, action: "paused", server: record(extended), base: missing)
            let result = try #require(plan.record.flatMap(CloudSyncController.makePayload))
            #expect(result.isPaused)
        }
    }

    @Test func syncBaseStoresAndRemovesARecord() throws {
        let id = "sync-base-test-\(UUID().uuidString)"
        let saved = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: id))
        CloudSyncController.applyFields(from: running(), to: saved)
        CloudSyncController.SyncBase.store(saved, timerID: id)
        let loaded = try #require(CloudSyncController.SyncBase.load(timerID: id))
        #expect(loaded.recordID.recordName == id)
        #expect(CloudSyncController.makePayload(from: loaded)?.label == "Pasta")
        CloudSyncController.SyncBase.remove(timerID: id)
        #expect(CloudSyncController.SyncBase.load(timerID: id) == nil)
    }

    @Test func aLaterTapIsNotUndoneWhenAnEarlierPushSettles() {
        let base = running()
        let pause = base.paused(at: t0.addingTimeInterval(30))
        // +1:00 tapped and stored before the pause's push came back.
        var later = pause.extended(by: 60)
        later.updatedAt = t0.addingTimeInterval(31)
        var serverNow = base.extended(by: 300)
        serverNow.updatedAt = t0.addingTimeInterval(60)
        let settled = CloudSyncController.settlement(pushed: pause, stored: later, serverNow: serverNow, at: t0.addingTimeInterval(61))
        #expect(settled == .init(storeBase: false, replaceStored: false))
        // Deleted meanwhile: nothing either.
        #expect(CloudSyncController.settlement(pushed: pause, stored: nil, serverNow: serverNow) == .init(storeBase: false, replaceStored: false))
        // The server holds exactly what was pushed: base only, no save or re-arm.
        #expect(CloudSyncController.settlement(pushed: pause, stored: pause, serverNow: pause, at: t0.addingTimeInterval(61)) == .init(storeBase: true, replaceStored: false))
    }

    @Test func thePushBaseIsReadWithTheSnapshot() {
        let callBase = record(running())
        var other = running()
        other.label = "Own save"
        let own = record(other)
        let called = t0.addingTimeInterval(10)
        // An earlier push of this process saved after this one was called: that's the ancestor.
        #expect(CloudSyncController.pushBase(callTimeBase: callBase, ownSave: (own, called.addingTimeInterval(1)), calledAt: called) === own)
        // Saved before the call: the call-time base already reflects it.
        #expect(CloudSyncController.pushBase(callTimeBase: callBase, ownSave: (own, called.addingTimeInterval(-1)), calledAt: called) === callBase)
        #expect(CloudSyncController.pushBase(callTimeBase: callBase, ownSave: nil, calledAt: called) === callBase)
    }

    @Test func twoQuickPushesFromThisPhoneLandInOrder() throws {
        let base = running()
        let pause = base.paused(at: t0.addingTimeInterval(30))
        var plusOne = pause.extended(by: 60)
        plusOne.updatedAt = t0.addingTimeInterval(31)
        // The pause's push saved; the +1:00 push plans against that own save.
        let savedPause = record(pause, actor: "Me", action: "paused")
        let plan = CloudSyncController.plannedPush(local: plusOne, action: "extended", server: savedPause, base: savedPause)
        let result = try #require(plan.record.flatMap(CloudSyncController.makePayload))
        #expect(result.isPaused)
        #expect(abs((result.pausedRemaining ?? 0) - (plusOne.pausedRemaining ?? 0)) < 0.001)
    }

    @Test func aStaleRenameDoesNotOverwriteANewerRename() throws {
        let base = running()
        var theirs = base
        theirs.label = "Tea"
        theirs.updatedAt = t0.addingTimeInterval(60)
        var mine = base
        mine.label = "Soup"
        mine.updatedAt = t0.addingTimeInterval(30)
        #expect(CloudSyncController.plannedPush(local: mine, action: "edited", server: record(theirs), base: record(base)).record == nil)
        // Renamed after theirs: ours wins.
        mine.updatedAt = t0.addingTimeInterval(90)
        let sent = try #require(CloudSyncController.plannedPush(local: mine, action: "edited", server: record(theirs), base: record(base)).record)
        #expect(sent["label"] as? String == "Soup")
    }

    @Test func anOwnSaveThatKeptAnotherPhonesChangeIsNotTheNextAncestor() {
        let base = running()
        let pause = base.paused(at: t0.addingTimeInterval(30))
        // Saved exactly as pushed: the next queued push may build on it.
        #expect(CloudSyncController.ownSaveIsAncestor(pushed: pause, saved: record(pause), at: t0.addingTimeInterval(31)))
        // The server kept another phone's rename: not an ancestor of our next snapshot.
        var merged = pause
        merged.label = "Tea"
        #expect(!CloudSyncController.ownSaveIsAncestor(pushed: pause, saved: record(merged), at: t0.addingTimeInterval(31)))
    }

    @Test func pushesOfOneTimerRunInCallOrderOneAtATime() async {
        let queue = CloudSyncController.PushQueue()
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let remaining = OSAllocatedUnfairLock(initialState: 3)
            for (index, delay) in [0.3, 0.1, 0.0].enumerated() {
                queue.run("same") { done in
                    log.withLock { $0.append("start \(index)") }
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        log.withLock { $0.append("end \(index)") }
                        done()
                        if remaining.withLock({ $0 -= 1; return $0 }) == 0 { finished.resume() }
                    }
                }
            }
        }
        #expect(log.withLock { $0 } == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
    }

    @Test func aRenameKeptByTheFirstQueuedPushSurvivesTheSecond() throws {
        let base = running()
        var renamed = base
        renamed.label = "Tea"
        renamed.updatedAt = t0.addingTimeInterval(20)
        // Push 1 (pause, newer) lands on the renamed record and keeps the rename.
        let pause = base.paused(at: t0.addingTimeInterval(30))
        let first = try #require(CloudSyncController.plannedPush(local: pause, action: "paused", server: record(renamed), base: record(base)).record)
        #expect(first["label"] as? String == "Tea")
        // Push 2 (+1:00) was built from the stored copy, which still says "Pasta".
        var plusOne = pause.extended(by: 60)
        plusOne.updatedAt = t0.addingTimeInterval(31)
        let calledAt = t0.addingTimeInterval(31), savedAt = t0.addingTimeInterval(32)
        let ownSave = CloudSyncController.ownSaveIsAncestor(pushed: pause, saved: first, at: savedAt) ? (record: first, at: savedAt) : nil
        let chosen = CloudSyncController.pushBase(callTimeBase: record(base), ownSave: ownSave, calledAt: calledAt)
        let second = try #require(CloudSyncController.plannedPush(local: plusOne, action: "extended", server: first, base: chosen).record)
        #expect(second["label"] as? String == "Tea")
        #expect(abs(((second["pausedRemaining"] as? Double) ?? 0) - (plusOne.pausedRemaining ?? 0)) < 0.001)
        // The previous rule (always the own save) loses the rename.
        let before = try #require(CloudSyncController.plannedPush(local: plusOne, action: "extended", server: first, base: first).record)
        #expect(before["label"] as? String == "Pasta")
    }
}

