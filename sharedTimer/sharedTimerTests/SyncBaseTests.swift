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
        for payload in [running(), running().paused(at: t0.addingTimeInterval(30)), sequence, annual] {
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
        // Nothing of ours survives: send nothing, take the server's copy.
        #expect(plan.record == nil)
        #expect(plan.adoptsServer)
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
        // The server had a change we lack (now overwritten whole, timing is one state),
        // so the local copy still re-reads the saved record.
        #expect(plan.adoptsServer)
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
        #expect(plan.adoptsServer)
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
            #expect(!plan.adoptsServer)
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
}
