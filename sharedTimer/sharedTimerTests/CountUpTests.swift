//
//  CountUpTests.swift
//  sharedTimerTests
//
//  N6 days since and N7 stopwatch: pure date math, in the 14 Pro's zone (US/Pacific)
//  as well as India, across midnight and a DST change.
//

import Foundation
import Testing
@testable import sharedTimer

@Suite(.serialized)
struct CountUpTests {
    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func date(_ s: String, _ zone: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    @Test func daysTickOverAtMidnightNotAfter24Hours() {
        let c = calendar("America/Los_Angeles")
        let item = DaysSince(label: "x", startDate: date("2026-11-16 23:30", "America/Los_Angeles"), calendar: c)
        #expect(item.days(at: date("2026-11-16 23:59", "America/Los_Angeles"), calendar: c) == 0)
        #expect(item.days(at: date("2026-11-17 00:01", "America/Los_Angeles"), calendar: c) == 1)
        #expect(item.days(at: date("2026-11-28 08:00", "America/Los_Angeles"), calendar: c) == 12)
    }

    @Test func aDSTChangeStillCountsAsOneDay() {
        // US fall-back was 2026-11-01; India has no DST.
        for zone in ["America/Los_Angeles", "Asia/Kolkata"] {
            let c = calendar(zone)
            let item = DaysSince(label: "x", startDate: date("2026-10-31 12:00", zone), calendar: c)
            #expect(item.days(at: date("2026-11-01 12:00", zone), calendar: c) == 1)
            #expect(item.days(at: date("2026-11-02 00:30", zone), calendar: c) == 2)
        }
        let spring = calendar("America/Los_Angeles")
        let item = DaysSince(label: "x", startDate: date("2026-03-07 09:00", "America/Los_Angeles"), calendar: spring)
        #expect(item.days(at: date("2026-03-09 09:00", "America/Los_Angeles"), calendar: spring) == 2)
    }

    @Test func countTextReadsTodayDaysThenYearsAndMonths() {
        let c = calendar("Asia/Kolkata")
        let item = DaysSince(label: "x", startDate: date("2025-09-03 10:00", "Asia/Kolkata"), calendar: c)
        #expect(item.countText(at: date("2025-09-03 20:00", "Asia/Kolkata"), calendar: c) == String(localized: "Today"))
        #expect(item.countText(at: date("2025-09-04 10:00", "Asia/Kolkata"), calendar: c) == "1 day")
        #expect(item.countText(at: date("2025-09-15 10:00", "Asia/Kolkata"), calendar: c) == "12 days")
        let long = item.countText(at: date("2026-11-28 10:00", "Asia/Kolkata"), calendar: c)
        #expect(long.contains("1") && long.contains("2"), "\(long)")
        #expect(DaysSince(label: "x", startDate: date("2026-12-01 10:00", "Asia/Kolkata"), calendar: c).days(at: date("2026-11-28 10:00", "Asia/Kolkata"), calendar: c) == 0)
    }

    @Test func aDayKeepsItsDateWhenThePhoneMovesZone() throws {
        // Made in India just after midnight on 16 Nov; read later in California.
        let india = calendar("Asia/Kolkata"), california = calendar("America/Los_Angeles")
        let item = DaysSince(label: "x", startDate: date("2026-11-16 00:30", "Asia/Kolkata"), calendar: india)
        #expect(item.year == 2026 && item.month == 11 && item.day == 16)
        #expect(item.days(at: date("2026-11-16 20:00", "America/Los_Angeles"), calendar: california) == 0)
        #expect(item.days(at: date("2026-11-17 08:00", "America/Los_Angeles"), calendar: california) == 1)
        // Round-trips as a day, and a first-build copy with an instant still decodes.
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(DaysSince.self, from: data) == item)
        let legacy = Data(#"{"id":"a","label":"Old","startDate":786240000}"#.utf8)
        #expect(try JSONDecoder().decode(DaysSince.self, from: legacy).label == "Old")
    }

    @Test func theStopwatchCountsPausesAndLaps() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var w = Stopwatch().started(at: t0)
        #expect(w.elapsed(at: t0.addingTimeInterval(10)) == 10)
        w = w.lapped(at: t0.addingTimeInterval(10))
        w = w.lapped(at: t0.addingTimeInterval(25))
        w = w.paused(at: t0.addingTimeInterval(30))
        #expect(!w.isRunning)
        #expect(w.elapsed(at: t0.addingTimeInterval(500)) == 30)
        #expect(w.lapped(at: t0.addingTimeInterval(40)) == w)   // no laps while paused
        w = w.started(at: t0.addingTimeInterval(100))
        #expect(w.elapsed(at: t0.addingTimeInterval(105)) == 35)
        #expect(w.lapLengths == [10, 15])
        #expect(w.currentLap(at: t0.addingTimeInterval(105)) == 10)
        #expect(w.started(at: t0.addingTimeInterval(200)) == w)  // already running
    }

    @Test func stopwatchTextShowsHoursOnceReached() {
        #expect(Stopwatch.text(252.37) == "04:12.37")
        #expect(Stopwatch.text(3_725.5, hundredths: false) == "1:02:05")
        #expect(Stopwatch.text(-3) == "00:00.00")
    }

    @Test func theStoreRoundTripsAndKeepsWhatItCannotRead() throws {
        let suite = "count-ups-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let saved = CountUpStore.defaults
        CountUpStore.defaults = defaults
        defer { CountUpStore.defaults = saved; defaults.removePersistentDomain(forName: suite) }
        CountUpStore.update { $0.daysSince.append(DaysSince(label: "Quit coffee", startDate: Date())); $0.stopwatch = Stopwatch().started() }
        let loaded = CountUpStore.load()
        #expect(loaded.daysSince.map(\.label) == ["Quit coffee"])
        #expect(loaded.stopwatch?.isRunning == true)
        let garbage = Data("nope".utf8)
        defaults.set(garbage, forKey: "countUps.v1")
        CountUpStore.update { $0.daysSince.removeAll() }
        #expect(defaults.data(forKey: "countUps.v1") == garbage)
    }
}
