import Foundation
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import sharedTimerWatch_Watch_App

@MainActor
struct sharedTimerWatch_Watch_AppTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func timer(_ id: String, seconds: Double, paused: Double? = nil) -> TimerPayload {
        TimerPayload(id: id, label: id, endDate: now.addingTimeInterval(seconds), duration: 300, pausedRemaining: paused)
    }

    @Test func selectsEarliestRunningBeforePaused() {
        let timers = [timer("paused", seconds: -100, paused: 60), timer("later", seconds: 200), timer("soon", seconds: 50)]
        #expect(WatchTimerSnapshot.select(timers, at: now).timer?.id == "soon")
        #expect(WatchTimerSnapshot.select([timers[0]], at: now).status == "Paused")
    }
    @Test func configuredTimerDoesNotSwitchAfterDeletion() {
        #expect(WatchTimerSnapshot.select([timer("other", seconds: 100)], id: "deleted", at: now).timer == nil)
        #expect(WatchTimerSnapshot.select([timer("done", seconds: -1)], id: "done", at: now).status == "Done")
    }
    @Test func timelineCompletesAtEndWithoutAnotherSync() {
        let entries = WatchTimerSnapshot.timeline([timer("tea", seconds: 100)], id: nil, at: now)
        #expect(entries.count == 2)
        #expect(entries[0].remaining == 100)
        #expect(entries[1].date == now.addingTimeInterval(100))
        #expect(entries[1].status == "Done")
        #expect(!entries[1].isRunning)
    }
    @Test func pausedCountdownIsFrozen() {
        let paused = timer("tea", seconds: -100, paused: 80)
        let entries = WatchTimerSnapshot.timeline([paused], id: "tea", at: now.addingTimeInterval(1000))
        #expect(entries.count == 1)
        #expect(entries[0].remaining == 80)
        #expect(abs(entries[0].progress - 80.0 / 300) < 0.0001)
    }
    @Test func emptyAndExpiredDefaultStayEmpty() {
        #expect(WatchTimerSnapshot.select([], at: now).status == "No Timers")
        #expect(WatchTimerSnapshot.select([timer("expired", seconds: -1)], at: now).timer == nil)
    }
    @Test func cacheRoundTripsReplacesAndClears() throws {
        let suite = "watch-cache-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(WatchTimerCache.load(from: defaults).isEmpty)
        #expect(WatchTimerCache.save([timer("tea", seconds: 100)], to: defaults))
        #expect(WatchTimerCache.load(from: defaults).first?.id == "tea")
        #expect(WatchTimerCache.save([timer("coffee", seconds: 200, paused: 90)], to: defaults))
        #expect(WatchTimerCache.load(from: defaults).count == 1)
        #expect(WatchTimerCache.load(from: defaults).first?.pausedRemaining == 90)
        #expect(WatchTimerCache.save([], to: defaults))
        #expect(WatchTimerCache.load(from: defaults).isEmpty)
        defaults.set(Data("corrupt".utf8), forKey: WatchTimerCache.key)
        #expect(WatchTimerCache.load(from: defaults).isEmpty)
    }
    @Test func renderComplicationStatesForVisualReview() throws {
        let states: [(String, TimerPayload?)] = [
            ("paused", timer("A long timer name for tea", seconds: 100, paused: 80)),
            ("long-paused", timer("Vacation", seconds: 0, paused: 31 * 86400)),
            ("done", timer("Tea", seconds: -1)),
            ("empty", nil)
        ]
        for (name, timer) in states {
            for family in [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline] {
                let width: CGFloat = family == .accessoryCircular ? 58 : 170
                let height: CGFloat = family == .accessoryInline ? 24 : 64
                let view = WatchTimerWidgetView(snapshot: WatchTimerSnapshot(date: now, timer: timer), family: family)
                    .frame(width: width, height: height).background(Color.black).foregroundStyle(.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let data = NSMutableData()
                let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
                Attachment.record(data as Data, named: "watch-\(family)-\(name).png")
            }
        }
    }

    @Test func receivedSnapshotsPersistRestoreAndDelete() throws {
        let suite = "watch-sync-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = WatchSyncController(defaults: defaults)
        let data = try JSONEncoder().encode([timer("tea", seconds: 100)])
        sync.apply(["timers": data])
        #expect(sync.timers.first?.id == "tea")
        #expect(WatchSyncController(defaults: defaults).timers.first?.id == "tea")
        sync.apply(["timers": Data("invalid".utf8)])
        #expect(sync.timers.first?.id == "tea")
        sync.apply(["timers": try JSONEncoder().encode([TimerPayload]())])
        #expect(sync.timers.isEmpty)
        #expect(WatchSyncController(defaults: defaults).timers.isEmpty)
    }

    @Test func linksRoundTripAndRejectPayloads() throws {
        let id = "tea / #?💫"
        let url = try #require(WatchTimerLink.url(id: id))
        #expect(WatchTimerLink.id(from: url) == id)
        #expect(WatchTimerLink.id(from: URL(string: "sharedtimer-watch://timer/")!) == nil)
        #expect(WatchTimerLink.id(from: URL(string: "sharedtimer-watch://timer/tea?duration=60")!) == nil)
        #expect(WatchTimerLink.id(from: URL(string: "https://timer/tea")!) == nil)
        #expect(WatchTimerLink.id(from: URL(string: "sharedtimer-watch://user@timer/tea")!) == nil)
    }
}
