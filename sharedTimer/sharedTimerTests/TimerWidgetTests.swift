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

    @Test func runningRingMatchesDurationAndCapsExtendedProgress() throws {
        let now = Date()
        let payload = TimerPayload(id: UUID().uuidString, label: "Tea", endDate: now.addingTimeInterval(60), duration: 120)
        let snapshot = TimerWidgetSnapshot(payload: payload, at: now)
        #expect(snapshot.progress == 0.5)
        let range = try #require(snapshot.timerInterval)
        #expect(range.lowerBound == now.addingTimeInterval(-60))
        #expect(range.upperBound == payload.endDate)
        let extended = TimerWidgetSnapshot(payload: payload.extended(by: 180), at: now)
        #expect(extended.progress == 1)
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

    @Test func timelinePrecomputesPendingStartPhaseChangesAndFinalFinish() throws {
        let now = Date()
        let start = now.addingTimeInterval(120)
        let phases = [SequencePhase(label: "Work", duration: 60), SequencePhase(label: "Rest", duration: 30)]
        let payload = TimerPayload.composeSequence(label: "Session", phases: phases, loopCount: 1, startDate: start)
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
        let scheduled = TimerPayload.composeSequence(label: "Morning session", phases: [SequencePhase(label: "Work", duration: 60)], loopCount: 1, startDate: now.addingTimeInterval(120))
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
