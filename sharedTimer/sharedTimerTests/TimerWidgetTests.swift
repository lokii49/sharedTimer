import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import sharedTimer

@Suite(.serialized) @MainActor
struct TimerWidgetTests {
    @Test func widgetLinksUseOnlyAnIDAndRejectOtherRoutes() throws {
        for id in ["123", "shared:timer/with spaces", "Café", "a?b#c%"] {
            let url = TimerAppLink.url(for: id)
            #expect(TimerAppLink.timerID(from: url) == id)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil)
            #expect(TimerPayload.from(url: url) == nil)
        }
        for value in ["sharedtimer://timer/", "sharedtimer://other/123", "https://timer/123", "sharedtimer://timer/123?end=42", "sharedtimer://timer/123#fragment"] {
            #expect(TimerAppLink.timerID(from: try #require(URL(string: value))) == nil)
        }
    }

    @Test func pausedRingFreezesAndAZeroPauseReadsFinished() {
        let now = Date()
        let running = TimerPayload(id: UUID().uuidString, label: "Pasta", endDate: now.addingTimeInterval(150), duration: 300)
        let paused = running.paused(at: now)
        let snapshot = TimerWidgetSnapshot(payload: paused, at: now.addingTimeInterval(1000))
        #expect(snapshot.status == .paused)
        #expect(snapshot.remaining == 150)
        #expect(snapshot.progress == 0.5)
        #expect(snapshot.timerInterval == nil)
        let zero = TimerWidgetSnapshot(payload: running.paused(at: now.addingTimeInterval(300)), at: now)
        #expect(zero.status == .finished)
        #expect(zero.progress == 0)
    }

    @Test func runningRingMatchesDurationAndKeepsDrainingWhenExtended() throws {
        let now = Date()
        let payload = TimerPayload(id: UUID().uuidString, label: "Tea", endDate: now.addingTimeInterval(60), duration: 120)
        let snapshot = TimerWidgetSnapshot(payload: payload, at: now)
        #expect(snapshot.progress == 0.5)
        let range = try #require(snapshot.timerInterval)
        #expect(range.lowerBound == now.addingTimeInterval(-60))
        #expect(range.upperBound == payload.endDate)
        // 240s left of a 300s run (120 + 180 extended), not a full ring.
        let extended = TimerWidgetSnapshot(payload: payload.extended(by: 180), at: now)
        #expect(abs(extended.progress - 0.8) < 0.001)
        #expect(try #require(extended.timerInterval).lowerBound == now.addingTimeInterval(-60))
        let finished = TimerWidgetSnapshot(payload: payload, at: payload.endDate)
        #expect(finished.status == .finished)
        #expect(finished.timerInterval == nil)
    }

    @Test func configuredFinishedAndFocusedPausedTimersStaySelected() throws {
        let now = Date()
        let finished = TimerPayload(id: "finished", label: "Done", endDate: now.addingTimeInterval(-60), duration: 60)
        let paused = TimerPayload(id: "paused", label: "Paused", endDate: now.addingTimeInterval(-120), duration: 120, pausedRemaining: 90)
        let running = TimerPayload(id: "running", label: "Running", endDate: now.addingTimeInterval(300), duration: 300)
        let all = [finished, paused, running]
        #expect(TimerWidgetSnapshot.resolve(from: all, selectedID: "finished", focusID: "paused", at: now)?.id == "finished")
        #expect(TimerWidgetSnapshot.resolve(from: all, selectedID: nil, focusID: "paused", at: now)?.id == "paused")
        #expect(TimerWidgetSnapshot.resolve(from: all, selectedID: nil, focusID: "finished", at: now)?.id == "finished")
        #expect(TimerWidgetSnapshot.resolve(from: all, selectedID: "deleted", focusID: nil, at: now)?.id == "running")
        #expect(TimerWidgetSnapshot.resolve(from: all, selectedID: nil, focusID: "finished", at: now.addingTimeInterval(3541))?.id == "paused")
        #expect(TimerWidgetSnapshot.resolve(from: [], selectedID: "deleted", focusID: nil, at: now) == nil)
    }

    @Test func scheduledTimelineRefreshesAtMidnightSoTheDayLabelRollsOver() {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: 3, to: now)!
        let payload = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 60)], loopCount: 1, startDate: start)
        let dates = TimerWidgetSnapshot.timeline(payload: payload, at: now).map(\.date)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        #expect(dates.contains(midnight))
        #expect(dates.contains(start))
    }

    @Test func timelinePrecomputesPendingStartPhaseChangesAndFinalFinish() throws {
        let now = Date()
        let start = now.addingTimeInterval(120)
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let payload = TimerPayload.composeSequence(phases: phases, loopCount: 1, startDate: start)
        let entries = TimerWidgetSnapshot.timeline(payload: payload, at: now)
        #expect(entries.map(\.date) == [now, start, start.addingTimeInterval(60), start.addingTimeInterval(90)])
        #expect(entries.map(\.status) == [.scheduled, .running, .running, .finished])
        #expect(entries[0].progress == 0)
        #expect(entries[1].progress == 1)
        #expect(entries[2].payload?.label == "Rest")
        #expect(TimerWidgetSnapshot.refreshDate(for: entries) == start.addingTimeInterval(91))
        #expect(TimerWidgetSnapshot.timeline(payload: payload, at: now, limit: 2).count == 3)
    }

    @Test func timelineCatchesUpStaleSequencesAndExcludesCancelledOnesFromAutoSelection() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        var payload = TimerPayload(id: "seq", label: "Work", endDate: now.addingTimeInterval(-10), duration: 60, sequence: SequenceInfo(phases: phases, loopCount: 2, phaseIndex: 0, loopIndex: 0))
        let entries = TimerWidgetSnapshot.timeline(payload: payload, at: now)
        #expect(entries[0].payload?.label == "Rest")
        #expect(entries[0].remaining == 20)
        #expect(entries.last?.status == .finished)
        payload.sequence?.loopIndex = 2
        payload.endDate = now.addingTimeInterval(300)
        #expect(TimerWidgetSnapshot(payload: payload, at: now).status == .finished)
        #expect(TimerWidgetSnapshot.resolve(from: [payload], selectedID: nil, focusID: nil, at: now) == nil)
    }

    /// A later phase of a day or more shows coarse "2d 0h" text: the refresh must come
    /// within an hour of that phase starting, not only at the very end.
    @Test func laterLongSequencePhaseGetsItsOwnCoarseRefresh() {
        let now = Date()
        let phases = [SequencePhase(label: "Work", duration: 3600), SequencePhase(label: "Break", duration: 2 * 86400)]
        let payload = TimerPayload(id: UUID().uuidString, label: "Work", endDate: now.addingTimeInterval(3600), duration: 3600,
                                   sequence: SequenceInfo(phases: phases, loopCount: 1, phaseIndex: 0, loopIndex: 0))
        let entries = TimerWidgetSnapshot.timeline(payload: payload, at: now)
        #expect(entries.map(\.date).contains(now.addingTimeInterval(3600)))
        // "2d 0h" turns into "1d 23h" one second into that phase (it rounds down).
        #expect(TimerWidgetSnapshot.refreshDate(for: entries) == now.addingTimeInterval(3601))
    }

    /// Home widgets: an entry at the finish (Repeat, no 0:00 with Pause/✕), sky-drain
    /// steps in between, all ascending from now, within the cap.
    @Test func homeTimelineCoversTheFinishAndDrainsTheSky() {
        let now = Date()
        let timer = TimerPayload(id: UUID().uuidString, label: "Tea", endDate: now.addingTimeInterval(600), duration: 600)
        let entries = TimerWidgetSnapshot.homeTimeline(payload: timer, at: now)
        #expect(entries.first?.date == now)
        #expect(entries.map(\.date) == entries.map(\.date).sorted())
        #expect(entries.contains { $0.date == timer.endDate && $0.status == .finished })
        #expect(entries.count > 3 && entries.count <= 40)
        #expect(entries.filter { $0.status == .running }.map(\.progress) == entries.filter { $0.status == .running }.map(\.progress).sorted(by: >))
        // The finished auto-selected timer gives way an hour after its end; no polling.
        #expect(TimerWidgetSnapshot.reloadDate(for: [entries.last!]) == timer.endDate.addingTimeInterval(3600))
    }

    /// A multi-day countdown's "3d 4h" changes on the hour: entries, not reloads.
    @Test func coarseDayTextRollsOverInEntriesAndReloadsOnlyPastThem() {
        let now = Date()
        let trip = TimerPayload(id: UUID().uuidString, label: "Trip", endDate: now.addingTimeInterval(3 * 86400 + 4 * 3600 + 60), duration: 4 * 86400, kind: .countdown)
        let entries = TimerWidgetSnapshot.homeTimeline(payload: trip, at: now)
        #expect(entries.contains { abs($0.date.timeIntervalSince(now.addingTimeInterval(61))) < 0.001 })
        let reload = TimerWidgetSnapshot.reloadDate(for: entries)
        // Half a day of hourly changes needs no reload at all…
        #expect(reload > now.addingTimeInterval(12 * 3600))
        // …because every hour boundary before the reload has its own entry.
        var boundary = now.addingTimeInterval(61)
        while boundary < reload {
            #expect(entries.contains { abs($0.date.timeIntervalSince(boundary)) < 0.001 })
            boundary = boundary.addingTimeInterval(3600)
        }
    }

    /// Paused, empty and long-finished widgets don't poll every 15 min: every store save
    /// reloads them, with a 6 h safety net.
    @Test func frozenWidgetsOnlyKeepASlowSafetyNet() {
        let now = Date()
        let idle = now.addingTimeInterval(TimerWidgetSnapshot.idleReloadInterval)
        let paused = TimerPayload(id: UUID().uuidString, label: "Tea", endDate: now.addingTimeInterval(600), duration: 600).paused(at: now)
        #expect(TimerWidgetSnapshot.reloadDate(for: TimerWidgetSnapshot.homeTimeline(payload: paused, at: now)) == idle)
        #expect(TimerWidgetSnapshot.reloadDate(for: TimerWidgetSnapshot.homeTimeline(payload: nil, at: now)) == idle)
        let longFinished = TimerPayload(id: UUID().uuidString, label: "Old", endDate: now.addingTimeInterval(-7200), duration: 60)
        #expect(TimerWidgetSnapshot.reloadDate(for: [TimerWidgetSnapshot(payload: longFinished, at: now)]) == idle)
    }

    /// The list judges each row on the entries it really keeps: a multi-day row next to
    /// a short timer reloads within the hour its coarse text needs, not hours later.
    @Test func listReloadUsesTheListsOwnEntries() {
        let now = Date()
        let tea = TimerPayload(id: UUID().uuidString, label: "Tea", endDate: now.addingTimeInterval(600), duration: 600)
        let trip = TimerPayload(id: UUID().uuidString, label: "Trip", endDate: now.addingTimeInterval(3 * 86400 + 4 * 3600 + 60), duration: 4 * 86400, kind: .countdown)
        let dates = TimerWidgetSnapshot.listDates(for: [tea, trip], at: now)
        let reload = TimerWidgetSnapshot.listReloadDate(for: [tea, trip], dates: dates, at: now)
        // Every hour boundary of the trip before the reload is one of the list's dates.
        var boundary = now.addingTimeInterval(61)
        while boundary < reload {
            #expect(dates.contains { abs($0.timeIntervalSince(boundary)) < 0.001 })
            boundary = boundary.addingTimeInterval(3600)
        }
    }

    /// The list widget gets every listed timer's finish as an entry.
    @Test func listDatesIncludeEachTimersFinish() {
        let now = Date()
        let a = TimerPayload(id: UUID().uuidString, label: "A", endDate: now.addingTimeInterval(120), duration: 120)
        let b = TimerPayload(id: UUID().uuidString, label: "B", endDate: now.addingTimeInterval(900), duration: 900)
        let dates = TimerWidgetSnapshot.listDates(for: [a, b], at: now)
        #expect(dates.first == now)
        #expect(dates.contains(a.endDate) && dates.contains(b.endDate))
        #expect(dates.count <= 40)
    }

    @Test func coarseCountdownRefreshesAtDayThresholdAndPausedTimelineStaysFrozen() {
        let now = Date()
        let far = TimerPayload(id: UUID().uuidString, label: "Trip", endDate: now.addingTimeInterval(86410), duration: 100000, kind: .countdown)
        let entries = TimerWidgetSnapshot.timeline(payload: far, at: now)
        #expect(TimerWidgetSnapshot.refreshDate(for: entries) == now.addingTimeInterval(10))
        let paused = far.paused(at: now)
        let pausedEntries = TimerWidgetSnapshot.timeline(payload: paused, at: now)
        #expect(pausedEntries.count == 1)
        #expect(TimerWidgetSnapshot.refreshDate(for: pausedEntries) == now.addingTimeInterval(900))
        let empty = TimerWidgetSnapshot.timeline(payload: nil, at: now)
        #expect(empty.count == 1)
        #expect(empty.first?.status == .empty)
    }

    /// Static state/layout renders for visual QA. Native timer-driven rings require
    /// the real WidgetKit host; these attachments verify paused/scheduled/empty/done.
    @Test func renderAccessoryStatesForVisualReview() throws {
        let now = Date()
        let running = TimerPayload(id: UUID().uuidString, label: "A long timer name for a study break", endDate: now.addingTimeInterval(150), duration: 300)
        let scheduled = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 60)], loopCount: 1, startDate: now.addingTimeInterval(120))
        let cases: [(String, TimerPayload?)] = [
            ("paused", running.paused(at: now)),
            ("finished", TimerPayload(id: UUID().uuidString, label: "Pasta", endDate: now.addingTimeInterval(-1), duration: 300)),
            ("scheduled", scheduled),
            ("empty", nil)
        ]
        for family in [WidgetFamily.accessoryCircular, .accessoryRectangular] {
            for (name, payload) in cases {
                let view = TimerAccessoryWidgetView(snapshot: TimerWidgetSnapshot(payload: payload, at: now), family: family)
                    .frame(width: family == .accessoryCircular ? 64 : 160, height: 64)
                    .environment(\.colorScheme, .dark)
                    .background(Color.black)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try #require(renderer.uiImage)
                let data = try #require(image.pngData())
                Attachment.record(data, named: "\(name)-\(family == .accessoryCircular ? "circular" : "rectangular").png")
            }
        }
    }
}
