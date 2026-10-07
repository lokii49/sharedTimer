//
//  AlarmKitDeviceTests.swift
//  sharedTimerTests
//
//  Integration tests against the REAL AlarmManager — they schedule actual alarms and
//  read them back, so they only run where AlarmKit is authorized for this app (a
//  physical device where "Allow" was tapped once). Skipped on the simulator/CI.
//  Every test uses fresh UUID timer ids and awaits its own teardown.
//
//  What they can't check: anything visual (Live Activity / Dynamic Island timing,
//  the alert actually ringing, button taps) — see ROADMAP's Phase 6 device checks.
//

import AlarmKit
import Foundation
import Testing
@testable import sharedTimer

@Suite(.serialized, .enabled(if: AlarmManager.shared.authorizationState == .authorized))
final class AlarmKitDeviceTests {
    /// Every payload a test armed. Each test ends
    /// with `await tearDown()` — a `defer { Task { ... } }` isn't awaited and leaves
    /// real alarms scheduled on the device after the run.
    private var created: [TimerPayload] = []

    private func tearDown() async {
        for payload in created {
            if TimerStore.loadAll().contains(where: { $0.id == payload.id }) {
                TimerStore.delete(id: payload.id)
            }
            await AlarmController.cancelSequenceAlarms(for: payload)
            if let id = UUID(uuidString: payload.id) { try? AlarmManager.shared.cancel(id: id) }
        }
        created.removeAll()
    }

    private func alarmsByID() -> [UUID: Alarm] {
        Dictionary(((try? AlarmManager.shared.alarms) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// `clear(_:)` is fire-and-forget through the per-id serializer — poll briefly.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 where !condition() {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Work 60s / Rest 30s, `loops` times, currently on occurrence `index`, phase
    /// ending at `end`.
    private func sequence(loops: Int, index: Int = 0, end: Date) -> TimerPayload {
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let seq = SequenceInfo(phases: phases, loopCount: loops, phaseIndex: index % 2, loopIndex: index / 2)
        let phase = phases[index % 2]
        return TimerPayload(id: UUID().uuidString, label: phase.label, endDate: end, duration: phase.duration, kind: .timer, sequence: seq)
    }

    private func phaseIDs(_ payload: TimerPayload, _ range: Range<Int>) -> [UUID] {
        range.map { AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: $0) }
    }

    @Test func sequencePrearmsWindowOfEightWithFixedFuturePhases() async {
        let payload = sequence(loops: 6, end: Date().addingTimeInterval(60))  // 12 occurrences
        created.append(payload)

        await AlarmController.rescheduleAwaiting(for: payload)
        let alarms = alarmsByID()

        let window = payload.upcomingSequencePhases(limit: AlarmController.sequenceWindow)
        #expect(window.count == 8)
        for id in phaseIDs(payload, 0..<8) {
            #expect(alarms[id] != nil, "phase alarm missing")
        }
        for id in phaseIDs(payload, 8..<12) {
            #expect(alarms[id] == nil, "armed beyond the window")
        }

        // Current phase: plain countdown config, no fixed schedule.
        let current = alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)]
        #expect(current?.schedule == nil)
        #expect(abs((current?.countdownDuration?.preAlert ?? 0) - 60) < 2)

        // Future phases: .fixed(end_k) with a duration-long countdown before it.
        for occurrence in window.dropFirst() {
            let alarm = alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: occurrence.globalIndex)]
            guard case .fixed(let date)? = alarm?.schedule else {
                Issue.record("occurrence \(occurrence.globalIndex) not .fixed: \(String(describing: alarm?.schedule))")
                continue
            }
            #expect(abs(date.timeIntervalSince(occurrence.endDate)) < 1)
            #expect(abs((alarm?.countdownDuration?.preAlert ?? 0) - occurrence.phase.duration) < 1)
            #expect(alarm?.state == .scheduled)
        }
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))
        await tearDown()
    }

    @Test func reschedulingUnchangedSequenceKeepsTheSameAlarmSet() async {
        let payload = sequence(loops: 3, end: Date().addingTimeInterval(60))
        created.append(payload)

        await AlarmController.rescheduleAwaiting(for: payload)
        let before = alarmsByID().filter { phaseIDs(payload, 0..<6).contains($0.key) }
        await AlarmController.rescheduleAwaiting(for: payload)
        let after = alarmsByID().filter { phaseIDs(payload, 0..<6).contains($0.key) }

        #expect(Set(before.keys) == Set(after.keys))
        #expect(before.count == 6)
        for (id, alarm) in before {
            #expect(after[id]?.schedule == alarm.schedule)
        }
        await tearDown()
    }

    @Test func nextFromTheCardCancelsTheSkippedPhaseAndRearmsTheRest() async {
        let start = Date()
        let payload = sequence(loops: 3, end: start.addingTimeInterval(60))
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)]?.state == .countdown)

        // "Next" tapped on the Live Activity mid-phase, through the real action path:
        // occurrence 0 is still counting down (not alerting), so it must go — on
        // device it lingered as a second Lock Screen card.
        TimerStore.save(payload)
        await LiveActivityActions.advanceSequence(timerID: payload.id, phaseIndex: 0)
        let onOne = try? #require(TimerStore.loadAll().first { $0.id == payload.id })
        #expect(onOne?.sequenceGlobalIndex == 1)
        guard let onOne else { await tearDown(); return }
        let alarms = alarmsByID()

        #expect(alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)] == nil, "skipped phase's alarm still armed")
        #expect(alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 1)]?.state == .countdown)
        let window = onOne.upcomingSequencePhases(limit: AlarmController.sequenceWindow)
        for occurrence in window.dropFirst() {
            let alarm = alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: occurrence.globalIndex)]
            guard case .fixed(let date)? = alarm?.schedule else {
                Issue.record("occurrence \(occurrence.globalIndex) not re-armed")
                continue
            }
            #expect(abs(date.timeIntervalSince(occurrence.endDate)) < 1)
        }
        await tearDown()
    }

    @Test func pausedSequenceKeepsCurrentPausedAndDisarmsTheRest() async {
        let payload = sequence(loops: 2, end: Date().addingTimeInterval(60))
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)] != nil)

        // Pause keeps phase 0 alive in AlarmKit's paused state; only the pre-armed
        // future phases are dropped.
        await AlarmController.rescheduleAwaiting(for: payload.paused())
        let alarms = alarmsByID()
        #expect(alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)]?.state == .paused)
        for id in phaseIDs(payload, 1..<4) {
            #expect(alarms[id] == nil)
        }
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))
        await tearDown()
    }

    @Test func pendingSequencePinsPhaseZeroToFixedEndDate() async {
        let start = Date().addingTimeInterval(600)
        let payload = TimerPayload.composeSequence(
            label: "Later",
            phases: [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)],
            loopCount: 1, startDate: start
        )
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)

        let first = alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)]
        guard case .fixed(let date)? = first?.schedule else {
            Issue.record("pending phase 0 not .fixed: \(String(describing: first?.schedule))")
            await tearDown()
            return
        }
        #expect(abs(date.timeIntervalSince(start.addingTimeInterval(60))) < 1)
        #expect(abs((first?.countdownDuration?.preAlert ?? 0) - 60) < 1)
        await tearDown()
    }

    @Test func clearAndEndSequenceRemoveEveryPhaseAlarm() async {
        let deleted = sequence(loops: 3, end: Date().addingTimeInterval(60))
        created.append(deleted)
        await AlarmController.rescheduleAwaiting(for: deleted)
        #expect(phaseIDs(deleted, 0..<6).allSatisfy { alarmsByID()[$0] != nil })
        AlarmController.clear(deleted)
        await waitUntil { phaseIDs(deleted, 0..<6).allSatisfy { alarmsByID()[$0] == nil } }
        #expect(phaseIDs(deleted, 0..<6).allSatisfy { alarmsByID()[$0] == nil })
        #expect(TimerStore.isAlarmKitArmed(id: deleted.id) == false)

        let ended = sequence(loops: 3, end: Date().addingTimeInterval(60))
        created.append(ended)
        await AlarmController.rescheduleAwaiting(for: ended)
        await AlarmController.cancelSequenceAlarms(for: ended)
        #expect(phaseIDs(ended, 0..<6).allSatisfy { alarmsByID()[$0] == nil })
        await tearDown()
    }

    @Test func legacySingleIDAlarmIsCancelledOnFirstSequenceReschedule() async {
        // A 1.0.3 build armed every sequence phase under the timer's own id.
        let payload = sequence(loops: 2, end: Date().addingTimeInterval(60))
        let legacyID = UUID(uuidString: payload.id)!
        created.append(payload)

        await AlarmController.rescheduleAwaiting(for: TimerPayload(id: payload.id, label: "Legacy", endDate: payload.endDate, duration: 60))
        #expect(alarmsByID()[legacyID] != nil, "setup: plain path should arm the legacy id")

        await AlarmController.rescheduleAwaiting(for: payload)
        let alarms = alarmsByID()
        #expect(alarms[legacyID] == nil)
        #expect(alarms[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)] != nil)
        await tearDown()
    }

    @Test func plainTimerKeepsSingleLegacyIDAndRegistry() async {
        let payload = TimerPayload(label: "Plain", duration: 120)
        created.append(payload)
        let id = UUID(uuidString: payload.id)!
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(alarmsByID()[id] != nil)
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))

        AlarmController.clear(id: payload.id)
        await waitUntil { alarmsByID()[id] == nil }
        #expect(alarmsByID()[id] == nil)
        #expect(TimerStore.isAlarmKitArmed(id: payload.id) == false)
        await tearDown()
    }

    @Test func pausingKeepsTheAlarmPausedAndResumeRearmsIt() async {
        let payload = TimerPayload(label: "Pause me", duration: 300)
        created.append(payload)
        let id = UUID(uuidString: payload.id)!
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(alarmsByID()[id]?.state == .countdown)

        // Paused: kept in AlarmKit's paused state (its Live Activity shows Resume),
        // not cancelled.
        let paused = payload.paused()
        await AlarmController.rescheduleAwaiting(for: paused)
        #expect(alarmsByID()[id]?.state == .paused)
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))

        await AlarmController.rescheduleAwaiting(for: paused.resumed())
        #expect(alarmsByID()[id]?.state == .countdown)
        await tearDown()
    }

    @Test func extendingWhilePausedReplacesThePausedAlarmWithTheNewLength() async {
        let payload = TimerPayload(label: "Paused extend", duration: 300)
        created.append(payload)
        let id = UUID(uuidString: payload.id)!
        await AlarmController.rescheduleAwaiting(for: payload)
        let paused = payload.paused()
        await AlarmController.rescheduleAwaiting(for: paused)
        #expect(alarmsByID()[id]?.state == .paused)

        // +2 min while paused: still paused, and the alarm now counts the new time.
        let extended = paused.extended(by: 120)
        await AlarmController.rescheduleAwaiting(for: extended)
        let alarm = alarmsByID()[id]
        #expect(alarm?.state == .paused)
        #expect(abs((alarm?.countdownDuration?.preAlert ?? 0) - (extended.pausedRemaining ?? 0)) < 2)

        // Unchanged paused payload: left alone (same alarm, still paused).
        await AlarmController.rescheduleAwaiting(for: extended)
        #expect(alarmsByID()[id]?.state == .paused)

        await AlarmController.rescheduleAwaiting(for: extended.resumed())
        #expect(alarmsByID()[id]?.state == .countdown)
        await tearDown()
    }

    /// Removes alarms left behind by an earlier run of this suite (before teardown
    /// was awaited): anything AlarmKit holds for this app that no stored timer owns.
    @Test func sweepStrayTestAlarms() async {
        var owned: Set<UUID> = []
        for payload in TimerStore.loadAll() {
            if let id = UUID(uuidString: payload.id) { owned.insert(id) }
            if let seq = payload.sequence {
                let total = seq.phases.count * seq.loopCount
                owned.formUnion((0..<total).map { AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: $0) })
            }
        }
        for alarm in (try? AlarmManager.shared.alarms) ?? [] where !owned.contains(alarm.id) {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
        #expect(((try? AlarmManager.shared.alarms) ?? []).allSatisfy { owned.contains($0.id) })
    }
}
