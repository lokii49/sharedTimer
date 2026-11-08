//
//  TimerHistoryTests.swift
//  sharedTimerTests
//
//  The pure recording rules behind the on-device history (TimerHistory.swift).
//

import Foundation
import Testing
@testable import sharedTimer

struct TimerHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timer(_ id: String, endsIn offset: TimeInterval, duration: TimeInterval = 300) -> TimerPayload {
        TimerPayload(id: id, label: "Pasta", endDate: now.addingTimeInterval(offset), duration: duration, kind: .timer)
    }

    @Test func finishedTimerIsRecordedOnceAndRunningOneIsNot() {
        let runs = TimerHistory.endedRuns(stored: [timer("a", endsIn: -10), timer("b", endsIn: 60)], lastSeen: [:], now: now)
        #expect(runs.map(\.timerID) == ["a"])
        let first = TimerHistory.merged([], adding: runs, now: now)
        // A second scan (or a CloudKit echo of the same run) adds nothing.
        let second = TimerHistory.merged(first, adding: runs, now: now)
        #expect(first.count == 1 && second == first)
        #expect(second.first?.canRunAgain == true)
        #expect(second.first?.runAgainPayload()?.duration == 300)
    }

    @Test func runThatEndedThenRepeatedOrDeletedBeforeAScanIsStillRecorded() {
        let ended = timer("a", endsIn: -5)
        let repeated = timer("a", endsIn: 295)
        let repeatedRuns = TimerHistory.endedRuns(stored: [repeated], lastSeen: ["a": ended], now: now)
        #expect(repeatedRuns.count == 1 && repeatedRuns.first?.endedAt == ended.endDate)

        let deletedRuns = TimerHistory.endedRuns(stored: [], lastSeen: ["a": ended], now: now)
        #expect(deletedRuns.count == 1)
        // Deleted while still running: not a finished run.
        #expect(TimerHistory.endedRuns(stored: [], lastSeen: ["b": timer("b", endsIn: 60)], now: now).isEmpty)
    }

    @Test func sequenceIsRecordedOnlyWhenExhausted() {
        let phases = [SequencePhase(label: "Focus", duration: 60), SequencePhase(label: "Break", duration: 30)]
        let midway = TimerPayload(id: "s", label: "Focus", endDate: now.addingTimeInterval(-5), duration: 60, kind: .timer,
                                  sequence: SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0))
        #expect(TimerHistory.endedRun(midway, now: now) == nil)  // advances into Break
        let done = TimerHistory.endedRun(midway, now: now.addingTimeInterval(1_000))
        #expect(done?.label == "Focus" && done?.length == 180)
        #expect(done?.sequence?.phaseIndex == 0 && done?.runAgainPayload()?.sequence?.phases == phases)
    }

    @Test func countdownsCannotRunAgainAndOldEntriesArePruned() {
        let countdown = TimerPayload(id: "c", label: "Trip", endDate: now.addingTimeInterval(-60), duration: 86_400, kind: .countdown)
        let entry = TimerHistory.endedRun(countdown, now: now)
        #expect(entry?.canRunAgain == false && entry?.runAgainPayload() == nil)

        let old = TimerHistory.endedRun(timer("o", endsIn: -TimerHistory.retention - 60), now: now)!
        let kept = TimerHistory.merged([old], adding: [entry!], now: now)
        #expect(kept.map(\.timerID) == ["c"])
    }

    @Test func historyListsWrittenBeforeNewFieldsStillDecode() throws {
        let json = Data(#"[{"timerID":"x","endedAt":0}]"#.utf8)
        let entries = try JSONDecoder().decode([TimerHistoryEntry].self, from: json)
        #expect(entries.first?.kind == .timer && entries.first?.sequence == nil)
    }
}

struct SequenceDescriberTests {
    @Test func draftsAreClampedToWhatASequenceMayHold() {
        let draft = SequenceDraft(phases: [
            PhaseDraft(label: "  Focus ", minutes: 25),
            PhaseDraft(label: "   ", minutes: 5),               // empty label: dropped
            PhaseDraft(label: "Break", minutes: 0),             // under 1 s: clamped up
            PhaseDraft(label: "Fast", minutes: 600_000)          // over a year: clamped down
        ], loopCount: 500)
        let result = SequenceDescriber.phases(from: draft)
        #expect(result.phases.map(\.label) == ["Focus", "Break", "Fast"])
        #expect(result.phases.map(\.duration) == [1500, 1, 365 * 86_400])
        #expect(result.loopCount == 99)
        #expect(SequenceDescriber.phases(from: SequenceDraft(phases: [], loopCount: 0)).loopCount == 1)
    }
}

struct OwnTimerSyncTests {
    @Test func syncedButUnsharedOwnerLinksAreNotShared() {
        let synced = CloudLink(timerID: "a", recordName: "a", zoneName: "SharedTimers", zoneOwnerName: "__defaultOwner__", isOwner: true, shareRecordName: nil)
        let owned = CloudLink(timerID: "b", recordName: "b", zoneName: "SharedTimers", zoneOwnerName: "__defaultOwner__", isOwner: true, shareRecordName: "share-b")
        let joined = CloudLink(timerID: "c", recordName: "c", zoneName: "SharedTimers", zoneOwnerName: "_abc", isOwner: false, shareRecordName: nil)
        #expect(!synced.isShared)
        #expect(owned.isShared)
        #expect(joined.isShared)
    }
}
