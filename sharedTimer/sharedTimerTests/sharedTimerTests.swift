//
//  sharedTimerTests.swift
//  sharedTimerTests
//
//  Created by Lokesh Pudhari on 09/08/26.
//

import Foundation
import Testing
@testable import sharedTimer

// .serialized: the TimerStore tests below share one real App Group UserDefaults key
// (TimerStore's suite name isn't injectable) — Swift Testing's default parallel
// execution races two tests writing/reading that key at once otherwise.
@Suite(.serialized)
struct sharedTimerTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    // MARK: - TimerPayload.isFinished / isExpired (1.0.1 bug fix)

    @Test func pausedAtZeroReadsFinishedButStaysUnexpired() {
        let now = Date()
        let payload = TimerPayload(id: "t1", label: "Pasta", endDate: now, duration: 60)
        let paused = payload.paused(at: now)

        #expect(paused.isPaused)
        #expect(paused.remaining == 0)
        // isFinished drives list categorization: a paused timer at zero should read
        // as finished, not sit in "Active" forever.
        #expect(paused.isFinished == true)
        // isExpired drives the alarm/notification path, which must never fire just
        // because someone paused a timer — that invariant must hold regardless of
        // how close to zero the pause happened.
        #expect(paused.isExpired == false)
    }

    @Test func runningTimerIsNeitherFinishedNorExpired() {
        let payload = TimerPayload(id: "t2", label: "Tea", duration: 300)
        #expect(payload.isFinished == false)
        #expect(payload.isExpired == false)
    }

    @Test func unpausedTimerPastEndDateIsFinishedAndExpired() {
        let payload = TimerPayload(
            id: "t3", label: "Eggs",
            endDate: Date().addingTimeInterval(-5), duration: 1
        )
        #expect(payload.isFinished == true)
        #expect(payload.isExpired == true)
    }

    // MARK: - TimerStore.loadAll resilience (1.0.1 bug fix)

    @Test func loadAllSkipsOnlyTheMalformedEntry() throws {
        let defaults = try #require(UserDefaults(suiteName: "group.com.lokesh.sharedTimer"))
        let originalData = defaults.data(forKey: "sharedTimers")
        defer {
            if let originalData {
                defaults.set(originalData, forKey: "sharedTimers")
            } else {
                defaults.removeObject(forKey: "sharedTimers")
            }
        }

        let good = TimerPayload(id: "good-1", label: "Good", duration: 60)
        let goodData = try JSONEncoder().encode(good)
        let goodDict = try JSONSerialization.jsonObject(with: goodData)
        // Missing every required field bar `id` — guaranteed to fail TimerPayload's decode.
        let badDict: [String: Any] = ["id": "bad-1"]
        let raw = try JSONSerialization.data(withJSONObject: [goodDict, badDict])
        defaults.set(raw, forKey: "sharedTimers")

        let loaded = TimerStore.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "good-1")
        // The JSONSerialization round-trip is where a Date-as-Double could drift —
        // assert the field that's actually at risk, not just that decoding succeeded.
        #expect(loaded.first?.endDate == good.endDate)
    }

    @Test func loadAllSkipsAWronglyTypedArrayElement() throws {
        let defaults = try #require(UserDefaults(suiteName: "group.com.lokesh.sharedTimer"))
        let originalData = defaults.data(forKey: "sharedTimers")
        defer {
            if let originalData {
                defaults.set(originalData, forKey: "sharedTimers")
            } else {
                defaults.removeObject(forKey: "sharedTimers")
            }
        }

        let good = TimerPayload(id: "good-2", label: "Good", duration: 60)
        let goodData = try JSONEncoder().encode(good)
        let goodDict = try JSONSerialization.jsonObject(with: goodData)
        // Not an object at all — casting the whole array straight to [[String: Any]]
        // fails on this and used to fall back to wiping every timer.
        let raw = try JSONSerialization.data(withJSONObject: [goodDict, "garbage"])
        defaults.set(raw, forKey: "sharedTimers")

        let loaded = TimerStore.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == "good-2")
    }

    // MARK: - TimerPayload.url() / .from(url:) round-trip

    @Test func urlRoundTripPreservesCoreFieldsAndDropsSequence() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60)]
        let seq = SequenceInfo(phases: phases, loopCount: 1, phaseIndex: 0, loopIndex: 0)
        let original = TimerPayload(
            id: "url-1", label: "Pasta", endDate: now, duration: 600,
            kind: .countdown, alarmEnabled: false, vibrationEnabled: true, sequence: seq
        )

        let decoded = try? #require(TimerPayload.from(url: original.url()))

        #expect(decoded?.id == original.id)
        #expect(decoded?.label == original.label)
        // `end` is seconds-since-1970 as a string — round-trips through Double, not exact
        // Date equality (sub-millisecond drift is possible), so compare within a tolerance.
        #expect(abs((decoded?.endDate.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970) < 0.001)
        #expect(decoded?.duration == original.duration)
        #expect(decoded?.kind == .countdown)
        #expect(decoded?.alarmEnabled == false)
        #expect(decoded?.vibrationEnabled == true)
        // sequence is main-app-only — never round-tripped through the share link.
        #expect(decoded?.sequence == nil)
    }

    @Test func urlAlarmAbsentDecodesTrueVibAbsentDecodesFalse() throws {
        // Simulates a link shared before the alarm/vibration toggles existed: no
        // `alarm` or `vib` query item at all, not even "0"/"1".
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        components.queryItems = [
            URLQueryItem(name: "id", value: "old-link"),
            URLQueryItem(name: "label", value: "Legacy"),
            URLQueryItem(name: "end", value: String(Date().timeIntervalSince1970 + 300)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer")
        ]
        let url = try #require(components.url)

        let decoded = try #require(TimerPayload.from(url: url))

        #expect(decoded.alarmEnabled == true)
        #expect(decoded.vibrationEnabled == false)
    }

    @Test func urlAlarmZeroDecodesFalseVibOneDecodesTrue() throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lokii49.github.io"
        components.path = "/sharedTimer/t.html"
        components.queryItems = [
            URLQueryItem(name: "id", value: "new-link"),
            URLQueryItem(name: "label", value: "Fresh"),
            URLQueryItem(name: "end", value: String(Date().timeIntervalSince1970 + 300)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "1")
        ]
        let url = try #require(components.url)

        let decoded = try #require(TimerPayload.from(url: url))

        #expect(decoded.alarmEnabled == false)
        #expect(decoded.vibrationEnabled == true)
    }

    // MARK: - TimerPayload JSON back-compat decode

    @Test func jsonDecodeBackCompatsMissingToggleAndSequenceFields() throws {
        // Golden fixture: an old-format stored/synced payload predating `alarmEnabled`,
        // `vibrationEnabled`, `kind`, and `sequence` entirely.
        let json = """
        {"id":"legacy-1","label":"Legacy","endDate":\(Date().timeIntervalSinceReferenceDate + 60),"duration":60}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let decoded = try decoder.decode(TimerPayload.self, from: json)

        #expect(decoded.kind == .timer)
        #expect(decoded.alarmEnabled == true)
        #expect(decoded.vibrationEnabled == false)
        #expect(decoded.sequence == nil)
    }

    // MARK: - SavedSequence decode (no back-compat init yet — golden-fixture guard)

    @Test func savedSequenceDecodesCurrentShapeDirectly() throws {
        let original = [
            SavedSequence(
                id: "seq-1", name: "Pomodoro",
                phases: [SequencePhase(label: "Work", duration: 1500), SequencePhase(label: "Rest", duration: 300)],
                loopCount: 4
            )
        ]
        let data = try JSONEncoder().encode(original)
        // Decoded straight from JSONDecoder, not `SavedSequenceStore.loadAll()` — that
        // swallows any decode error into `[]`, which would hide the exact regression
        // this test exists to catch (see CLAUDE.md on adding fields to SequencePhase).
        let decoded = try JSONDecoder().decode([SavedSequence].self, from: data)

        #expect(decoded == original)
    }

    // MARK: - TimerPayload.advancedSequence(at:) / steppedToNextPhase(at:) / repeated(at:)

    @Test func advancedSequenceCatchesUpAcrossMultiplePhasesAndLoops() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let seq = SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0)
        // endDate == now: phase 0 (Work) already ended exactly at `now`.
        let payload = TimerPayload(id: "adv-1", label: "Work", endDate: now, duration: 60, kind: .timer, sequence: seq)

        // Backgrounded 100s: Work(60)->Rest(30, ends+90)->Work(loop2, ends+150)->Rest(ends+180).
        // At now+100 the walk stops having just entered loop2's Rest phase (ends at now+120).
        let advanced = payload.advancedSequence(at: now.addingTimeInterval(100))

        #expect(advanced.sequence?.phaseIndex == 1)
        #expect(advanced.sequence?.loopIndex == 1)
        #expect(advanced.label == "Rest")
        #expect(advanced.duration == 30)
        #expect(advanced.endDate == now.addingTimeInterval(120))
    }

    @Test func advancedSequenceSettlesExhaustedAfterFinalLoop() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let seq = SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0)
        let payload = TimerPayload(id: "adv-2", label: "Work", endDate: now, duration: 60, kind: .timer, sequence: seq)

        // Total sequence length is 180s; asking far beyond that must settle exhausted,
        // not loop or spin — bounded by phases.count * loopCount, not by elapsed time.
        let advanced = payload.advancedSequence(at: now.addingTimeInterval(10_000))

        #expect(advanced.sequence?.loopIndex == 2)
    }

    @Test func steppedToNextPhaseAnchorsToTapTimeNotStaleBoundary() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let seq = SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0)
        // Stale endDate far in the past -- a real delay between the alert firing and the tap.
        let payload = TimerPayload(id: "step-1", label: "Work", endDate: now.addingTimeInterval(-500), duration: 60, kind: .timer, sequence: seq)

        let tapTime = now
        let stepped = payload.steppedToNextPhase(at: tapTime)

        // Exactly one phase forward, timed from `tapTime` -- not chained off the stale
        // endDate the way advancedSequence(at:) would be.
        #expect(stepped.sequence?.phaseIndex == 1)
        #expect(stepped.sequence?.loopIndex == 0)
        #expect(stepped.label == "Rest")
        #expect(stepped.endDate == tapTime.addingTimeInterval(30))
    }

    @Test func steppedToNextPhaseOnFinalPhaseExhaustsWithoutOverwritingFields() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        // Already on the final phase of the final loop.
        let seq = SequenceInfo(phases: phases, loopCount: 1, phaseIndex: 1, loopIndex: 0)
        let payload = TimerPayload(id: "step-2", label: "Rest", endDate: now, duration: 30, kind: .timer, sequence: seq)

        let stepped = payload.steppedToNextPhase(at: now.addingTimeInterval(5))

        #expect(stepped.sequence?.loopIndex == 1)
        // No next phase to materialize -- label/duration/endDate stay whatever they were.
        #expect(stepped.label == "Rest")
        #expect(stepped.duration == 30)
    }

    @Test func repeatedResetsSequenceToPhaseZeroLoopZero() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", kind: .timer, duration: 60), SequencePhase(label: "Rest", kind: .timer, duration: 30)]
        let seq = SequenceInfo(phases: phases, loopCount: 3, phaseIndex: 1, loopIndex: 2)
        let payload = TimerPayload(id: "rep-1", label: "Rest", endDate: now, duration: 30, kind: .timer, sequence: seq)

        let repeated = payload.repeated(at: now)

        #expect(repeated.sequence?.phaseIndex == 0)
        #expect(repeated.sequence?.loopIndex == 0)
        #expect(repeated.label == "Work")
        #expect(repeated.duration == 60)
        #expect(repeated.endDate == now.addingTimeInterval(60))
        #expect(repeated.isPaused == false)
    }

    @Test func repeatedOnPlainPayloadKeepsOriginalDuration() {
        let now = Date()
        let payload = TimerPayload(id: "rep-2", label: "Tea", duration: 300)

        let repeated = payload.repeated(at: now)

        #expect(repeated.sequence == nil)
        #expect(repeated.endDate == now.addingTimeInterval(300))
    }

    // MARK: - TimerStore.persist prune, projected through advancedSequence()

    @Test func persistPrunesAnExhaustedSequenceOlderThan24h() throws {
        let defaults = try #require(UserDefaults(suiteName: "group.com.lokesh.sharedTimer"))
        let originalData = defaults.data(forKey: "sharedTimers")
        defer {
            if let originalData {
                defaults.set(originalData, forKey: "sharedTimers")
            } else {
                defaults.removeObject(forKey: "sharedTimers")
            }
        }

        // Single one-loop phase whose endDate is 25h in the past: advancedSequence()
        // walks it straight to exhausted, and the projected endDate never moves
        // forward -- this must prune same as a plain expired timer would.
        let phases = [SequencePhase(label: "Work", duration: 60)]
        let seq = SequenceInfo(phases: phases, loopCount: 1, phaseIndex: 0, loopIndex: 0)
        let stale = TimerPayload(
            id: "prune-exhausted", label: "Work",
            endDate: Date().addingTimeInterval(-90_000), duration: 60, kind: .timer, sequence: seq
        )
        TimerStore.save(stale)

        let loaded = TimerStore.loadAll()
        #expect(loaded.contains { $0.id == "prune-exhausted" } == false)
    }

    @Test func persistKeepsAStaleSequenceStillMidwayThroughLaterPhases() throws {
        let defaults = try #require(UserDefaults(suiteName: "group.com.lokesh.sharedTimer"))
        let originalData = defaults.data(forKey: "sharedTimers")
        defer {
            if let originalData {
                defaults.set(originalData, forKey: "sharedTimers")
            } else {
                defaults.removeObject(forKey: "sharedTimers")
            }
        }

        // Phase 0 already 25h stale, but phase 1 is ~2.3 days long, so the projected
        // endDate lands in the future once advanced -- the raw (unadvanced) endDate
        // alone would wrongly look long-expired and get deleted.
        let phases = [SequencePhase(label: "Work", duration: 1), SequencePhase(label: "Rest", duration: 200_000)]
        let seq = SequenceInfo(phases: phases, loopCount: 1, phaseIndex: 0, loopIndex: 0)
        let midway = TimerPayload(
            id: "prune-midway", label: "Work",
            endDate: Date().addingTimeInterval(-90_000), duration: 1, kind: .timer, sequence: seq
        )
        TimerStore.save(midway)

        let loaded = TimerStore.loadAll()
        #expect(loaded.contains { $0.id == "prune-midway" } == true)
    }

}
