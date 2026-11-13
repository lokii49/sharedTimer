//
//  Audit108Tests.swift
//  sharedTimerTests
//
//  Pure decisions behind the 1.0.8 audit fixes (see CLAUDE.md "1.0.8 fixes"): the
//  CloudKit pull's link rules, SharePlay acceptance, the warm-foreground sequence
//  re-arm, the share-accept stamp margin, odd daylight-saving gaps, and back-compat of
//  the Live Activity state.
//

import Foundation
import Testing
@testable import sharedTimer

struct CloudPullDecisionTests {
    private func link(owner: Bool, share: String?) -> CloudLink {
        CloudLink(timerID: "t", recordName: "t", zoneName: "SharedTimers", zoneOwnerName: owner ? "__defaultOwner__" : "someone",
                  isOwner: owner, shareRecordName: share)
    }

    @Test func ownerLinkPicksUpANewOrDifferentShareButNeverClearsOne() {
        // Shared on another of this person's devices.
        #expect(CloudSyncController.ownerLink(link(owner: true, share: nil), afterPullingShare: "S1")?.shareRecordName == "S1")
        // Stopped and re-shared there: the new share replaces the old.
        #expect(CloudSyncController.ownerLink(link(owner: true, share: "S1"), afterPullingShare: "S2")?.shareRecordName == "S2")
        // Unchanged: nothing to write.
        #expect(CloudSyncController.ownerLink(link(owner: true, share: "S1"), afterPullingShare: "S1") == nil)
        // No share on the record: only the server check may clear it.
        #expect(CloudSyncController.ownerLink(link(owner: true, share: "S1"), afterPullingShare: nil) == nil)
        // Participants and unlinked timers are left alone.
        #expect(CloudSyncController.ownerLink(link(owner: false, share: nil), afterPullingShare: "S1") == nil)
        #expect(CloudSyncController.ownerLink(nil, afterPullingShare: "S1") == nil)
    }

    @Test func participantStrayCopiesInThePrivateZoneAreIgnored() {
        #expect(CloudSyncController.ignoresPrivateZoneChange(link: link(owner: false, share: "S")))
        #expect(!CloudSyncController.ignoresPrivateZoneChange(link: link(owner: true, share: nil)))
        #expect(!CloudSyncController.ignoresPrivateZoneChange(link: nil))
        #expect(CloudSyncController.appliesPrivateZoneDeletion(link: link(owner: true, share: nil)))
        #expect(!CloudSyncController.appliesPrivateZoneDeletion(link: link(owner: false, share: "S")))
        #expect(!CloudSyncController.appliesPrivateZoneDeletion(link: nil))
    }

    @Test func acceptKeepsALocalChangeOnlyIfItIsReallyNewer() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var server = TimerPayload(id: "t", label: "Tea", duration: 300)
        server.updatedAt = base
        var local = server
        local.updatedAt = base.addingTimeInterval(0.0004)  // the link's full precision vs CloudKit's ms
        #expect(!local.hasChange(newerThan: server))
        local.updatedAt = base.addingTimeInterval(5)
        #expect(local.hasChange(newerThan: server))
        local.updatedAt = nil
        #expect(!local.hasChange(newerThan: server))
        server.updatedAt = nil
        local.updatedAt = base
        #expect(local.hasChange(newerThan: server))
    }
}

@MainActor
struct SharePlayAcceptTests {
    @Test func callUpdatesSkipSharedAndViewOnlyTimersAndOlderStamps() {
        var stored = TimerPayload(id: "t", label: "Tea", duration: 300)
        stored.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var newer = stored
        newer.updatedAt = stored.updatedAt!.addingTimeInterval(10)
        #expect(SharePlayController.accepts(newer, stored: nil, isShared: false, isReadOnly: false))
        #expect(SharePlayController.accepts(newer, stored: stored, isShared: false, isReadOnly: false))
        #expect(!SharePlayController.accepts(stored, stored: newer, isShared: false, isReadOnly: false))
        #expect(!SharePlayController.accepts(newer, stored: stored, isShared: true, isReadOnly: false))
        #expect(!SharePlayController.accepts(newer, stored: stored, isShared: false, isReadOnly: true))
    }
}

struct WarmForegroundRearmTests {
    private func sequence() -> TimerPayload {
        let phases = [SequencePhase(label: "Work", duration: 1500), SequencePhase(label: "Rest", duration: 300)]
        return TimerPayload(id: "s", label: "Work", endDate: Date().addingTimeInterval(1500), duration: 1500,
                            sequence: SequenceInfo(phases: phases, loopCount: 4, phaseIndex: 0, loopIndex: 0))
    }

    @Test func sequenceChangedWhileAwayIsRearmedAndAnUnchangedOneIsNot() {
        let running = sequence()
        #expect(!ContentView.sequenceNeedsRearm(before: running, now: running))
        #expect(ContentView.sequenceNeedsRearm(before: running, now: running.paused()))       // paused in Messages
        #expect(ContentView.sequenceNeedsRearm(before: running, now: running.extended(by: 60)))
        #expect(ContentView.sequenceNeedsRearm(before: nil, now: running))                     // new while away
        // Plain timers go through the plain-timer comparison instead.
        let plain = TimerPayload(id: "p", label: "Tea", duration: 300)
        #expect(!ContentView.sequenceNeedsRearm(before: nil, now: plain))
    }
}

/// Spring gaps that aren't a whole hour (Lord Howe: 30 min at 02:00; Chatham: 1 h at
/// 02:45). The rule's missing time moves to the first valid wall time on that day — as
/// on the web page — instead of skipping the day (Lord Howe) or overshooting (Chatham).
struct OddDaylightSavingGapTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func lordHoweThirtyMinuteGapStaysOnTheSameDay() throws {
        let zone = try #require(TimeZone(identifier: "Australia/Lord_Howe"))
        // 02:15 doesn't exist on 2027-10-03 (02:00 → 02:30, +11:00 after): 02:30 = 15:30Z on the 2nd.
        let daily = AnnualRecurrence(date: date("2027-09-30T15:45:00Z"), timeZone: zone, frequency: .daily)
        #expect(daily.hour == 2 && daily.minute == 15)
        #expect(daily.nextDate(after: date("2027-10-02T12:00:00Z")) == date("2027-10-02T15:30:00Z"))
        let yearly = AnnualRecurrence(date: date("2026-10-02T15:45:00Z"), timeZone: zone)  // Oct 3 02:15
        #expect(yearly.date(in: 2027) == date("2027-10-02T15:30:00Z"))
    }

    @Test func chathamGapUsesTheFirstValidMinute() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Chatham"))
        // 2027-09-26 02:45 → 03:45 (+13:45 after); a 02:50 rule lands on 03:45 = 14:00Z on the 25th.
        let daily = AnnualRecurrence(date: date("2027-09-23T14:05:00Z"), timeZone: zone, frequency: .daily)
        #expect(daily.hour == 2 && daily.minute == 50)
        #expect(daily.nextDate(after: date("2027-09-25T10:00:00Z")) == date("2027-09-25T14:00:00Z"))
    }
}

struct LiveActivityStateCompatTests {
    @Test func stateFromAnOlderBuildDecodesWithoutTheNewField() throws {
        let json = #"{"endDate":800000000,"label":"Tea"}"#
        let state = try JSONDecoder().decode(TimerActivityAttributes.ContentState.self, from: Data(json.utf8))
        #expect(state.noOvertime == nil && state.label == "Tea")
    }
}
