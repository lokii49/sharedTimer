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
import AppIntents
import CloudKit
import UserNotifications
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
            NotificationScheduler.cancel(id: payload.id)
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

    /// Exercise the actual Siri intent entry points, including persistence and the
    /// awaited arming path, rather than calling AlarmController directly.
    /// What AlarmController last scheduled for `id` (title|alarmEnabled). Only written
    /// when an alarm is actually (re)scheduled, so a changed value proves re-creation.
    private func signature(_ id: UUID) -> String? {
        (UserDefaults(suiteName: "group.com.lokesh.sharedTimer")?.dictionary(forKey: "alarmPresentationSignature") as? [String: String])?[id.uuidString]
    }

    @Test func editingAPausedTimerReplacesItsPausedAlarm() async {
        let payload = TimerPayload(label: "Edit paused", duration: 300)
        created.append(payload)
        let id = UUID(uuidString: payload.id)!
        await AlarmController.rescheduleAwaiting(for: payload)
        let paused = payload.paused()
        await AlarmController.rescheduleAwaiting(for: paused)
        #expect(alarmsByID()[id]?.state == .paused)
        #expect(signature(id) == "Edit paused|true")

        // Same paused time, new title and tone: the kept-paused path must not keep it.
        let edited = paused.edited(label: "Edited paused", alarmEnabled: false, vibrationEnabled: true)
        await AlarmController.rescheduleAwaiting(for: edited)
        #expect(alarmsByID()[id]?.state == .paused)
        #expect(signature(id) == "Edited paused|false")
        #expect(abs((alarmsByID()[id]?.countdownDuration?.preAlert ?? 0) - (edited.pausedRemaining ?? 0)) < 2)
        await tearDown()
    }

    @Test func editingAnAnnualCountdownReplacesItsFixedAlarms() async {
        let payload = TimerPayload.composeAnnual(label: "Edit annual", targetDate: Date().addingTimeInterval(3600), timeZone: .gmt)
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let ids = payload.upcomingAnnualDates().map { AlarmController.annualAlarmID(timerID: payload.id, year: payload.recurrence!.year(of: $0)) }
        #expect(ids.allSatisfy { signature($0) == "Edit annual|true" })

        let renamed = payload.edited(label: "Renamed annual", alarmEnabled: true, vibrationEnabled: true, targetDate: payload.endDate)
        await AlarmController.rescheduleAwaiting(for: renamed)
        #expect(ids.allSatisfy { alarmsByID()[$0] != nil && signature($0) == "Renamed annual|true" })

        // Moving the date re-anchors both years at the new wall time.
        let moved = renamed.edited(label: "Renamed annual", alarmEnabled: true, vibrationEnabled: true, targetDate: Date().addingTimeInterval(7200))
        await AlarmController.rescheduleAwaiting(for: moved)
        let alarms = alarmsByID()
        for end in moved.upcomingAnnualDates() {
            let id = AlarmController.annualAlarmID(timerID: moved.id, year: moved.recurrence!.year(of: end))
            if case .fixed(let actual)? = alarms[id]?.schedule { #expect(abs(actual.timeIntervalSince(end)) < 1) }
            else { Issue.record("Moved annual alarm is not fixed to its new date") }
        }
        await tearDown()
    }

    @Test @MainActor func siriIntentsPauseExtendResumeAndReadRealAlarm() async {
        let payload = TimerPayload(label: "Siri integration", duration: 300)
        created.append(payload)
        do {
            let id = try #require(UUID(uuidString: payload.id))
            TimerStore.save(payload)
            await TimerArming.armAwaiting(payload)
            let selection = TimerChoice(id: payload.id, label: "Old cached name")
            var pause = PauseTimerIntent()
            pause.timer = selection
            _ = try await pause.perform()
            let paused = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(paused.isPaused)
            #expect(paused.label == payload.label)
            #expect(alarmsByID()[id]?.state == .paused)
            let frozen = try #require(paused.pausedRemaining)

            // Repeating Pause must not reduce the frozen time or change the stamp.
            _ = try await pause.perform()
            let pausedAgain = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(pausedAgain.pausedRemaining == frozen)
            #expect(pausedAgain.updatedAt == paused.updatedAt)

            var extend = ExtendTimerIntent()
            extend.timer = selection
            extend.minutes = 2
            _ = try await extend.perform()
            let extended = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(extended.pausedRemaining == frozen + 120)
            #expect(alarmsByID()[id]?.state == .paused)
            #expect(abs((alarmsByID()[id]?.countdownDuration?.preAlert ?? 0) - (frozen + 120)) < 2)
            var remaining = GetTimerRemainingIntent()
            remaining.timer = selection
            let pausedResult = try await remaining.perform()
            #expect(pausedResult.value == frozen + 120)

            var resume = ResumeTimerIntent()
            resume.timer = selection
            _ = try await resume.perform()
            let running = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(!running.isPaused)
            #expect(alarmsByID()[id]?.state == .countdown)
            #expect(TimerStore.isAlarmKitArmed(id: payload.id))
            let runningResult = try await remaining.perform()
            let seconds = try #require(runningResult.value)
            #expect(abs(seconds - (frozen + 120)) < 3)
        } catch {
            Issue.record(error)
        }
        await tearDown()
    }

    @Test @MainActor func siriIntentCatchesUpSequenceAndRearmsFuturePhases() async {
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 300)]
        let payload = TimerPayload(id: UUID().uuidString, label: "Work", endDate: Date().addingTimeInterval(-10), duration: 60, sequence: SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0))
        created.append(payload)
        do {
            TimerStore.save(payload)
            let selection = TimerChoice(id: payload.id, label: "Work")
            var pause = PauseTimerIntent()
            pause.timer = selection
            _ = try await pause.perform()
            let paused = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(paused.label == "Rest")
            #expect(paused.sequenceGlobalIndex == 1)
            #expect(paused.isPaused)
            let currentID = AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 1)
            #expect(alarmsByID()[currentID]?.state == .paused)
            for id in phaseIDs(payload, 2..<4) { #expect(alarmsByID()[id] == nil) }

            var resume = ResumeTimerIntent()
            resume.timer = selection
            _ = try await resume.perform()
            #expect(alarmsByID()[currentID]?.state == .countdown)
            for id in phaseIDs(payload, 2..<4) { #expect(alarmsByID()[id]?.state == .scheduled) }
            var extend = ExtendTimerIntent()
            extend.timer = selection
            extend.minutes = 1
            _ = try await extend.perform()
            let extended = try #require(TimerStore.loadAll().first { $0.id == payload.id })
            #expect(extended.sequenceGlobalIndex == 1)
            for occurrence in extended.upcomingSequencePhases(limit: 8).dropFirst() {
                let id = AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: occurrence.globalIndex)
                guard case .fixed(let date)? = alarmsByID()[id]?.schedule else {
                    Issue.record("Future phase missing its fixed schedule")
                    continue
                }
                #expect(abs(date.timeIntervalSince(occurrence.endDate)) < 1)
            }
        } catch {
            Issue.record(error)
        }
        await tearDown()
    }

    @MainActor
    @Test func sharedSequenceLinkArmsReceiverWindowAndPauseClearsFuturePhases() async {
        let source = sequence(loops: 3, end: Date().addingTimeInterval(300))
        guard let received = TimerPayload.from(url: source.url()) else {
            Issue.record("Shared sequence link did not decode")
            return
        }
        created.append(received)
        TimerStore.save(received)
        await TimerArming.armAwaiting(received)
        #expect(received.sequence?.phases.count == 2)
        for id in phaseIDs(received, 0..<6) { #expect(alarmsByID()[id] != nil) }
        let paused = received.paused()
        TimerStore.save(paused)
        await TimerArming.armAwaiting(paused)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: received.id, globalIndex: 0)]?.state == .paused)
        for id in phaseIDs(received, 1..<6) { #expect(alarmsByID()[id] == nil) }
        let resumed = paused.resumed()
        TimerStore.save(resumed)
        await TimerArming.armAwaiting(resumed)
        for id in phaseIDs(received, 0..<6) { #expect(alarmsByID()[id] != nil) }
        await tearDown()
    }

    @MainActor
    @Test func sharedSequenceCloudProjectionArmsCurrentAndFuturePhases() async {
        let source = sequence(loops: 3, index: 2, end: Date().addingTimeInterval(300))
        let record = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: source.id))
        CloudSyncController.applyFields(from: source, to: record)
        guard let received = CloudSyncController.makePayload(from: record) else {
            Issue.record("Shared sequence record did not decode")
            return
        }
        created.append(received)
        TimerStore.save(received)
        await TimerArming.armAwaiting(received)
        #expect(received.sequenceGlobalIndex == 2)
        for id in phaseIDs(received, 0..<2) { #expect(alarmsByID()[id] == nil) }
        for occurrence in received.upcomingSequencePhases(limit: 8).dropFirst() {
            let id = AlarmController.phaseAlarmID(timerID: received.id, globalIndex: occurrence.globalIndex)
            guard case .fixed(let date)? = alarmsByID()[id]?.schedule else {
                Issue.record("Shared future phase missing")
                continue
            }
            #expect(abs(date.timeIntervalSince(occurrence.endDate)) < 1)
        }
        await tearDown()
    }

    @MainActor
    @Test func mixedSharedSequenceUsesOneAlertPerPhase() async {
        let now = Date()
        let phases = [SequencePhase(label: "Quiet work", duration: 300, alarmEnabled: false, vibrationEnabled: false),
                      SequencePhase(label: "Rest", duration: 30, alarmEnabled: true, vibrationEnabled: false)]
        let payload = TimerPayload(id: UUID().uuidString, label: "Quiet work", endDate: now.addingTimeInterval(300), duration: 300,
                                   alarmEnabled: false, vibrationEnabled: false,
                                   sequence: SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0))
        created.append(payload)
        TimerStore.save(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 0)] == nil)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 1)] != nil)
        #expect(alarmsByID()[AlarmController.phaseAlarmID(timerID: payload.id, globalIndex: 3)] != nil)
        #expect(TimerStore.isAlarmKitArmed(id: payload.id), "Extensions must preserve the main app's mixed alert window")
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("Mixed sequence notification authorization: \(settings.authorizationStatus.rawValue)")
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            var pending: [UNNotificationRequest] = []
            for _ in 0..<40 {
                pending = await center.pendingNotificationRequests().filter { ($0.content.userInfo["timerID"] as? String) == payload.id }
                if pending.count == 2 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            #expect(Set(pending.compactMap { $0.content.userInfo["sequenceGlobalIndex"] as? Int }) == [0, 2])
        }
        NotificationScheduler.cancel(id: payload.id)
        await tearDown()
    }

    @MainActor
    @Test func remoteSequenceDeletionClearsAlarmsAfterPayloadWasRemoved() async {
        let payload = sequence(loops: 3, index: 2, end: Date().addingTimeInterval(300))
        created.append(payload)
        TimerStore.save(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        TimerStore.delete(id: payload.id) // e.g. the Messages extension received deletion first.
        AlarmController.clear(id: payload.id)
        let ids = phaseIDs(payload, 2..<6)
        await waitUntil { ids.allSatisfy { alarmsByID()[$0] == nil } }
        #expect(ids.allSatisfy { alarmsByID()[$0] == nil })
        await tearDown()
    }

    @MainActor
    @Test func sharedSequenceNextAndCancelPersistShareableMutations() async {
        let payload = sequence(loops: 3, end: Date().addingTimeInterval(300))
        created.append(payload)
        TimerStore.save(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        await LiveActivityActions.advanceSequence(timerID: payload.id, phaseIndex: 0)
        guard let next = TimerStore.loadAll().first(where: { $0.id == payload.id }) else {
            Issue.record("Next removed the shared sequence")
            await tearDown()
            return
        }
        #expect(next.sequenceGlobalIndex == 1)
        #expect(next.updatedAt != nil)
        #expect(TimerPayload.from(url: next.url())?.sequenceGlobalIndex == 1)
        await LiveActivityActions.endSequence(timerID: payload.id)
        guard let done = TimerStore.loadAll().first(where: { $0.id == payload.id }) else {
            Issue.record("Cancel removed the shared sequence")
            await tearDown()
            return
        }
        #expect(done.isFinished)
        #expect(done.sequence?.loopIndex == done.sequence?.loopCount)
        #expect(done.updatedAt! >= next.updatedAt!)
        #expect(!done.alarmEnabled && !done.vibrationEnabled)
        #expect(TimerPayload.from(url: done.url())?.isFinished == true)
        #expect(done.repeated().alarmEnabled)
        for id in phaseIDs(payload, 0..<6) { #expect(alarmsByID()[id] == nil) }
        await tearDown()
    }

    /// Removes alarms left behind by an earlier run of this suite (before teardown
    /// was awaited): anything AlarmKit holds for this app that no stored timer owns.
    @Test func annualCountdownPrearmsTwoFixedDatesWithoutLongCountdown() async {
        let payload = TimerPayload.composeAnnual(label: "Annual device test", targetDate: Date().addingTimeInterval(3600), timeZone: .gmt)
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let dates = payload.upcomingAnnualDates()
        let alarms = alarmsByID()
        for end in dates {
            let id = AlarmController.annualAlarmID(timerID: payload.id, year: payload.recurrence!.year(of: end))
            #expect(alarms[id] != nil)
            if case .fixed(let actual)? = alarms[id]?.schedule { #expect(abs(actual.timeIntervalSince(end)) < 1) }
            else { Issue.record("Annual alarm is not fixed to its occurrence date") }
            #expect(alarms[id]?.countdownDuration == nil)
        }
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))
        await AlarmController.rescheduleAwaiting(for: payload)
        #expect(dates.allSatisfy { alarmsByID()[AlarmController.annualAlarmID(timerID: payload.id, year: payload.recurrence!.year(of: $0))] != nil })
        await tearDown()
    }

    @Test func pausingAnnualCountdownRemovesBothYearsAndResumeRestoresThem() async {
        let payload = TimerPayload.composeAnnual(label: "Annual pause test", targetDate: Date().addingTimeInterval(3600), timeZone: .gmt)
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let ids = payload.upcomingAnnualDates().map { AlarmController.annualAlarmID(timerID: payload.id, year: payload.recurrence!.year(of: $0)) }
        let paused = payload.paused()
        await AlarmController.rescheduleAwaiting(for: paused)
        #expect(ids.allSatisfy { alarmsByID()[$0] == nil })
        #expect(!TimerStore.isAlarmKitArmed(id: payload.id))
        await AlarmController.rescheduleAwaiting(for: paused.resumed())
        #expect(ids.allSatisfy { alarmsByID()[$0] != nil })
        await tearDown()
    }

    @Test @MainActor func nextAnnualIntentIsIdempotentAndStopDisablesTheSeries() async {
        let payload = TimerPayload.composeAnnual(label: "Annual intent test", targetDate: Date().addingTimeInterval(3600), timeZone: .gmt)
        created.append(payload)
        TimerStore.save(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let occurrenceEnd = payload.endDate.timeIntervalSince1970
        _ = try? await AdvanceAnnualCountdownIntent(timerID: payload.id, occurrenceEnd: occurrenceEnd).perform()
        let advanced = TimerStore.loadAll().first { $0.id == payload.id }
        #expect(advanced?.endDate == payload.recurrence!.nextDate(after: payload.endDate))
        #expect(advanced?.updatedAt ?? .distantPast >= payload.updatedAt!)
        #expect(TimerPayload.from(url: advanced?.url())?.recurrence == payload.recurrence)
        _ = try? await AdvanceAnnualCountdownIntent(timerID: payload.id, occurrenceEnd: occurrenceEnd).perform()
        #expect(TimerStore.loadAll().first { $0.id == payload.id }?.endDate == advanced?.endDate)
        await LiveActivityActions.stop(timerID: payload.id)
        let stopped = TimerStore.loadAll().first { $0.id == payload.id }
        #expect(stopped?.recurrence == nil)
        #expect(stopped?.isFinished == true)
        let years = payload.recurrence!.year(of: payload.endDate)...payload.recurrence!.year(of: payload.endDate) + 2
        #expect(years.allSatisfy { alarmsByID()[AlarmController.annualAlarmID(timerID: payload.id, year: $0)] == nil })
        await tearDown()
    }

    @Test func annualRemoteDeletionWorksAfterStoredPayloadIsGone() async {
        let payload = TimerPayload.composeAnnual(label: "Annual deletion test", targetDate: Date().addingTimeInterval(3600), timeZone: .gmt)
        created.append(payload)
        TimerStore.save(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let ids = payload.upcomingAnnualDates().map { AlarmController.annualAlarmID(timerID: payload.id, year: payload.recurrence!.year(of: $0)) }
        TimerStore.delete(id: payload.id)
        AlarmController.clear(id: payload.id)
        await waitUntil { ids.allSatisfy { alarmsByID()[$0] == nil } }
        #expect(ids.allSatisfy { alarmsByID()[$0] == nil })
        await tearDown()
    }

    @Test func extendingNewYearsEveDoesNotCollideWithNextOccurrence() async {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let year = calendar.component(.year, from: Date()) + 1
        let target = calendar.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59))!
        let payload = TimerPayload.composeAnnual(label: "Annual year boundary test", targetDate: target, timeZone: .gmt).extended(by: 120)
        created.append(payload)
        let dates = payload.upcomingAnnualDates()
        #expect(dates.count == 2)
        #expect(payload.recurrence!.year(of: dates[0]) == payload.recurrence!.year(of: dates[1]))
        await AlarmController.rescheduleAwaiting(for: payload)
        let alarms = alarmsByID()
        let ids = (0...1).map { AlarmController.annualAlarmID(timerID: payload.id, year: year + 1, slot: $0) }
        #expect(ids.allSatisfy { alarms[$0] != nil })
        for end in dates {
            #expect(ids.contains { id in
                guard case .fixed(let actual)? = alarms[id]?.schedule else { return false }
                return abs(actual.timeIntervalSince(end)) < 1
            })
        }
        await tearDown()
    }

    @Test func quietAnnualCountdownPrearmsBothNotificationDates() async {
        let payload = TimerPayload.composeAnnual(label: "Quiet annual device test", targetDate: Date().addingTimeInterval(3600),
                                                  timeZone: .gmt, alarmEnabled: false, vibrationEnabled: false)
        created.append(payload)
        await AlarmController.rescheduleAwaiting(for: payload)
        let center = UNUserNotificationCenter.current()
        var pending: [UNNotificationRequest] = []
        for _ in 0..<30 {
            pending = await center.pendingNotificationRequests().filter { $0.content.userInfo["timerID"] as? String == payload.id }
            if pending.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(pending.count == 2)
        #expect(!TimerStore.isAlarmKitArmed(id: payload.id))
        #expect(pending.allSatisfy { $0.content.userInfo["annualYear"] != nil })
        NotificationScheduler.cancel(id: payload.id)
        await tearDown()
    }

    @Test @MainActor func annualWidgetPauseAfterRolloverUsesNextAnniversary() async {
        let now = Date()
        let payload = TimerPayload.composeAnnual(label: "Annual widget rollover test", targetDate: now.addingTimeInterval(-3600),
                                                  timeZone: .gmt, at: now.addingTimeInterval(-7200))
        created.append(payload)
        TimerStore.save(payload)
        await LiveActivityActions.setPaused(timerID: payload.id, paused: true)
        let paused = TimerStore.loadAll().first { $0.id == payload.id }
        #expect(paused?.isPaused == true)
        #expect(paused?.pausedRemaining ?? 0 > 300 * 86400)
        #expect(paused?.recurrence == payload.recurrence)
        await LiveActivityActions.setPaused(timerID: payload.id, paused: false)
        let resumed = TimerStore.loadAll().first { $0.id == payload.id }
        #expect(resumed?.isPaused == false)
        #expect(TimerStore.isAlarmKitArmed(id: payload.id))
        await tearDown()
    }

    @Test func sweepStrayTestAlarms() async {
        var owned: Set<UUID> = []
        let stored = TimerStore.loadAll()
        let fixtureTitles: Set<String> = ["Annual device test", "Annual pause test", "Annual intent test", "Annual deletion test", "Annual year boundary test", "Quiet annual device test"]
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let orphanedFixtures = requests.filter { request in
            guard fixtureTitles.contains(request.content.title), let id = request.content.userInfo["timerID"] as? String else { return false }
            return !stored.contains { $0.id == id }
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: orphanedFixtures.map(\.identifier))
        for payload in stored {
            if let id = UUID(uuidString: payload.id) { owned.insert(id) }
            if payload.recurrence != nil {
                owned.formUnion((1...9998).flatMap { year in (0...1).map { AlarmController.annualAlarmID(timerID: payload.id, year: year, slot: $0) } })
            }
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
