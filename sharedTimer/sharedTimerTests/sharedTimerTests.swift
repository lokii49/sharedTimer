//
//  sharedTimerTests.swift
//  sharedTimerTests
//
//  Created by Lokesh Pudhari on 09/08/26.
//

import Foundation
import Testing
@testable import sharedTimer

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
    }

}
