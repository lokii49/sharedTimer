//
//  AppIntentsIndexTests.swift
//  sharedTimerTests
//
//  N9: TimerChoice as an IndexedEntity with filterable properties (Shortcuts' generated
//  Find action), its Spotlight link, and undo for Siri's Pause/Resume/Add/Remove Time.
//

import Foundation
import Testing
@testable import sharedTimer

@MainActor
struct AppIntentsIndexTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func phase(_ label: String, _ seconds: TimeInterval) -> SequencePhase {
        SequencePhase(label: label, kind: .timer, duration: seconds)
    }

    @Test func eachTimerReadsItsKindStateAndEnd() {
        let running = TimerPayload(id: "r", label: "Tea", endDate: now.addingTimeInterval(300), duration: 300)
        let paused = TimerPayload(id: "p", label: "Bread", endDate: now.addingTimeInterval(-50), duration: 600, pausedRemaining: 120)
        let done = TimerPayload(id: "d", label: "Eggs", endDate: now.addingTimeInterval(-1), duration: 60)
        let countdown = TimerPayload(id: "c", label: "Trip", endDate: now.addingTimeInterval(86_400), duration: 86_400, kind: .countdown)

        let r = TimerChoice(payload: running, at: now)
        #expect(r.kind == .timer && r.state == .running && r.endDate == running.endDate && r.label == "Tea")
        let p = TimerChoice(payload: paused, at: now)
        #expect(p.state == .paused)
        // A paused timer's end is "now + what's left", not its stale stored end.
        #expect(p.endDate == now.addingTimeInterval(120))
        #expect(TimerChoice(payload: done, at: now).state == .finished)
        #expect(TimerChoice(payload: countdown, at: now).kind == .countdown)
    }

    @Test func aSequenceIsReadAtItsCurrentPhaseAndAScheduledOneAsScheduled() {
        var seq = TimerPayload.composeSequence(phases: [phase("Work", 60), phase("Rest", 30)], loopCount: 1)
        let start = seq.endDate.addingTimeInterval(-60)
        // 70 s in: phase 2 ("Rest") is running.
        let later = start.addingTimeInterval(70)
        let choice = TimerChoice(payload: seq, at: later)
        #expect(choice.kind == .sequence && choice.label == "Rest" && choice.state == .running)
        #expect(TimerChoice(payload: seq, at: start.addingTimeInterval(200)).state == .finished)

        seq = TimerPayload.composeSequence(phases: [phase("Work", 60)], loopCount: 1, startDate: Date().addingTimeInterval(3_600))
        #expect(TimerChoice(payload: seq).state == .scheduled)
    }

    @Test func findSeesFinishedTimersButSuggestionsDoNot() {
        let running = TimerPayload(id: "r", label: "Tea", endDate: now.addingTimeInterval(300), duration: 300)
        let done = TimerPayload(id: "d", label: "Eggs", endDate: now.addingTimeInterval(-1), duration: 60)
        #expect(TimerChoiceQuery.all(from: [running, done], at: now).map(\.id) == ["d", "r"])
        #expect(TimerChoiceQuery.choices(from: [running, done], at: now).map(\.id) == ["r"])
    }

    @Test func equalityStaysIdAndName() {
        // ContentView refreshes Siri's timer list when choices change; a ticking end date
        // or a pause must not count as a change.
        let a = TimerChoice(id: "x", label: "Tea", kind: .timer, state: .running, endDate: now)
        let b = TimerChoice(id: "x", label: "Tea", kind: .timer, state: .paused, endDate: now.addingTimeInterval(60))
        #expect(a == b)
        #expect(a != TimerChoice(id: "x", label: "Chai"))
    }

    @Test func eachSiriChangeRegistersItsOpposite() async {
        func check(_ did: TimerIntentActions.Mutation, expect: String, name: String) async {
            let undo = UndoManager()
            undo.groupsByEvent = false
            var ran: (String, String)?
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                undo.beginUndoGrouping()
                IntentUndo.register(undo, timerID: "t", stamp: now, did: did, isCurrent: { _, _ in true }) { id, change in
                    ran = (id, "\(change)")
                    done.resume()
                }
                undo.endUndoGrouping()
                #expect(undo.undoActionName == name)
                undo.undo()
            }
            #expect(ran?.0 == "t")
            #expect(ran?.1 == expect)
        }
        await check(.pause, expect: "resume", name: String(localized: "Pause"))
        await check(.resume, expect: "pause", name: String(localized: "Resume"))
        await check(.extend(minutes: 5), expect: "shorten(minutes: 5.0)", name: String(localized: "Add Time"))
        await check(.shorten(minutes: 2), expect: "extend(minutes: 2.0)", name: String(localized: "Remove time"))
        // No undo manager (Siri with nothing to attach to): nothing registered, no crash.
        IntentUndo.register(nil, timerID: "t", stamp: now, did: .pause)
    }

    @Test func aStaleSiriUndoDoesNothing() async throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var performed = false
        var checked: (String, Date?)?
        undo.beginUndoGrouping()
        IntentUndo.register(undo, timerID: "t", stamp: now, did: .extend(minutes: 5),
                            isCurrent: { id, stamp in checked = (id, stamp); return false }) { _, _ in performed = true }
        undo.endUndoGrouping()
        undo.undo()
        try await Task.sleep(for: .milliseconds(200))
        #expect(checked?.0 == "t" && checked?.1 == now)
        #expect(!performed)
    }
}
