import CloudKit
import EventKit
import Foundation
import Testing
import UserNotifications
@testable import sharedTimer

@MainActor
struct AnnualCountdownTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func annual(_ target: String = "2028-02-29T09:30:00Z", zone: String = "GMT") -> AnnualRecurrence {
        AnnualRecurrence(date: date(target), timeZone: TimeZone(identifier: zone)!)
    }
    @Test func leapDayUsesLastDayOfFebruaryAndReturnsToLeapDay() {
        let rule = annual()
        #expect(rule.date(in: 2029) == date("2029-02-28T09:30:00Z"))
        #expect(rule.date(in: 2032) == date("2032-02-29T09:30:00Z"))
        #expect(rule.nextDate(after: date("2029-02-28T09:30:00Z")) == date("2030-02-28T09:30:00Z"))
    }
    @Test func skippedYearsCatchUpWithoutChangingMutationStamp() {
        let initial = date("2026-01-01T12:00:00Z")
        let target = date("2026-04-05T09:00:00Z")
        let source = TimerPayload.composeAnnual(label: "Anniversary", targetDate: target, timeZone: .gmt, at: initial)
        let projected = source.advancedSequence(at: date("2030-05-01T00:00:00Z"))
        #expect(projected.endDate == date("2031-04-05T09:00:00Z"))
        #expect(projected.updatedAt == initial)
        #expect(projected.advancedSequence(at: date("2030-05-01T00:00:00Z")).endDate == projected.endDate)
    }
    @Test func timeZoneAndSpringGapAreStable() {
        let rule = annual("2026-03-14T06:30:00Z", zone: "America/New_York") // 02:30 standard time
        #expect(rule.date(in: 2027) == date("2027-03-14T07:00:00Z")) // Missing 02:30 -> 03:00
        #expect(rule.date(in: 2028) == date("2028-03-14T06:30:00Z"))
        let repeated = annual("2025-11-01T05:30:00Z", zone: "America/New_York")
        #expect(repeated.date(in: 2026) == date("2026-11-01T05:30:00Z")) // First 01:30
    }
    @Test func invalidRulesAreRejectedAndExtremeDatesDoNotTrap() throws {
        var rule = annual()
        rule.month = 13; #expect(AnnualRecurrence.encode(rule) == nil)
        rule = annual(); rule.day = 30; #expect(!rule.isValid)
        rule = annual(); rule.timeZoneID = "No/Such_Zone"; #expect(!rule.isValid)
        #expect(AnnualRecurrence.decode(Data(repeating: 65, count: 2049)) == nil)
        #expect(annual().nextDate(after: date("9999-01-01T00:00:00Z")) == nil)
        let future = Data("{\"version\":2,\"recurrence\":{}}".utf8)
        #expect(AnnualRecurrence.decode(future) == nil)
    }
    @Test func pausesFreezeOccurrenceAndExtensionsDoNotMoveAnnualAnchor() {
        let start = date("2026-02-01T00:00:00Z")
        let source = TimerPayload.composeAnnual(label: "Birthday", targetDate: date("2026-02-28T09:30:00Z"), timeZone: .gmt, at: start)
        let paused = source.paused(at: start)
        #expect(paused.advancedSequence(at: date("2030-01-01T00:00:00Z")).endDate == source.endDate)
        let extended = paused.extended(by: 60)
        let resumed = extended.resumed(at: start)
        #expect(resumed.endDate == source.endDate.addingTimeInterval(60))
        #expect(resumed.recurrence == source.recurrence)
        #expect(resumed.advancedSequence(at: date("2026-03-01T00:00:00Z")).endDate == date("2027-02-28T09:30:00Z"))
    }
    @Test func linksAndStoragePreserveYearlyAnchorWithLegacyCompatibility() throws {
        let source = TimerPayload.composeAnnual(label: "Birthday 🎉", targetDate: Date().addingTimeInterval(7200))
        let linked = try #require(TimerPayload.from(url: source.url()))
        #expect(linked.recurrence == source.recurrence)
        #expect(linked.kind == .countdown)
        let stored = try JSONDecoder().decode(TimerPayload.self, from: JSONEncoder().encode(source))
        #expect(stored.recurrence == source.recurrence)
        var legacy = source; legacy.recurrence = nil
        #expect(TimerPayload.from(url: legacy.url())?.recurrence == nil)
        var parts = URLComponents(url: source.url(), resolvingAgainstBaseURL: false)!
        parts.queryItems?.append(URLQueryItem(name: "seq", value: "{}"))
        #expect(TimerPayload.from(url: parts.url) == nil)
    }
    @Test func cloudMappingPreservesAndClearsYearlyRules() throws {
        let source = TimerPayload.composeAnnual(label: "Birthday", targetDate: Date().addingTimeInterval(7200))
        let record = CKRecord(recordType: "Timer", recordID: CKRecord.ID(recordName: source.id))
        CloudSyncController.applyFields(from: source, to: record)
        #expect(CloudSyncController.makePayload(from: record)?.recurrence == source.recurrence)
        record["recurrenceData"] = Data("{}".utf8) as CKRecordValue
        #expect(CloudSyncController.makePayload(from: record) == nil)
        var plain = source; plain.recurrence = nil
        CloudSyncController.applyFields(from: plain, to: record)
        #expect(record["recurrenceData"] == nil)
        #expect(CloudSyncController.makePayload(from: record)?.recurrence == nil)
    }
    @Test func notificationWindowHasTwoIndependentDatesAndExcludesOnlyCoveredOccurrence() throws {
        let now = date("2026-01-01T00:00:00Z")
        let source = TimerPayload.composeAnnual(label: "Birthday", targetDate: date("2026-02-28T09:30:00Z"), timeZone: .gmt, alarmEnabled: false, vibrationEnabled: false, at: now)
        let dates = source.upcomingAnnualDates(at: now)
        #expect(dates == [date("2026-02-28T09:30:00Z"), date("2027-02-28T09:30:00Z")])
        let requests = NotificationScheduler.requests(for: source, at: now)
        #expect(requests.count == 2)
        #expect(requests.map(\.identifier) == ["\(source.id).phase.0", "\(source.id).phase.1"])
        #expect(requests[0].content.userInfo["annualYear"] as? Int == 2026)
        let remaining = NotificationScheduler.requests(for: source, at: now, excludingAnnualDates: [dates[0]])
        #expect(remaining.count == 1)
        #expect(remaining[0].identifier == requests[1].identifier)
        #expect(NotificationScheduler.requests(for: source.paused(at: now), at: now).isEmpty)
    }
    @Test func selectedPastAnniversaryStartsAtNextOccurrence() {
        let source = TimerPayload.composeAnnual(label: "", targetDate: date("2020-02-29T09:30:00Z"), timeZone: .gmt, at: date("2026-03-01T00:00:00Z"))
        #expect(source.endDate == date("2027-02-28T09:30:00Z"))
        #expect(source.label == "Countdown")
        #expect(source.repeated(at: date("2027-03-01T00:00:00Z")).endDate == date("2028-02-29T09:30:00Z"))
    }
    @Test func calendarImportCopiesOnlyEventTitleTimeAndAnnualRule() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Anniversary"
        event.startDate = date("2027-04-05T15:30:00Z")
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.timeZone = TimeZone(identifier: "Asia/Kolkata")
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil))
        let choice = CalendarCountdownChoice(event: event)
        #expect(choice.title == event.title)
        #expect(choice.date == event.startDate)
        #expect(choice.timeZone.identifier == "Asia/Kolkata")
        #expect(choice.repeatsYearly)
        let payload = TimerPayload.composeAnnual(label: choice.title, targetDate: choice.date, timeZone: choice.timeZone)
        #expect(payload.recurrence?.hour == 21)
        #expect(payload.recurrence?.minute == 0)
    }
    @Test func allDayImportUsesLocalMidnightAndWeeklyEventStaysOneOff() {
        let event = EKEvent(eventStore: EKEventStore())
        event.title = "Holiday"; event.startDate = date("2027-01-05T12:00:00Z")
        event.endDate = event.startDate.addingTimeInterval(86400); event.timeZone = .gmt; event.isAllDay = true
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        let choice = CalendarCountdownChoice(event: event)
        #expect(Calendar.current.component(.hour, from: choice.date) == 0)
        #expect(Calendar.current.component(.day, from: choice.date) == 5)
        #expect(choice.timeZone == .current) // EventKit all-day events have no time zone.
        #expect(!choice.repeatsYearly)
    }
    @Test func recurringCalendarOccurrencesHaveDistinctIDsAndRelativeYearlyRulesStayOneOff() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = "Annual Thursday meeting"; event.startDate = date("2027-11-25T12:00:00Z")
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .yearly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.thursday, weekNumber: 4)], daysOfTheMonth: nil,
            monthsOfTheYear: [11], weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil))
        let first = CalendarCountdownChoice(event: event)
        #expect(!first.repeatsYearly)
        event.startDate = date("2028-11-23T12:00:00Z")
        #expect(CalendarCountdownChoice(event: event).id != first.id)
    }

    @MainActor private final class Source: CalendarCountdownSource {
        var authorizationStatus: EKAuthorizationStatus = .fullAccess
        var allowed = true
        var failed = false
        var requested = 0
        var reads = 0
        var fixtures: [EKEvent] = []
        func requestAccess() async throws -> Bool { requested += 1; return allowed }
        func events(from start: Date, to end: Date) throws -> [EKEvent] {
            reads += 1
            if failed { throw NSError(domain: "Calendar fixture", code: 1) }
            return fixtures
        }
    }
    @Test func deniedAndRestrictedCalendarAccessNeverReadsEvents() async {
        let source = Source(); source.authorizationStatus = .denied
        let importer = CalendarCountdownImporter(source: source)
        await importer.load()
        #expect(source.requested == 0 && source.reads == 0)
        #expect(importer.needsSettings && importer.message != nil && !importer.isLoading)
        source.authorizationStatus = .restricted
        await importer.load()
        #expect(!importer.needsSettings && source.reads == 0)
    }
    @Test func newlyDeniedCalendarPermissionNeverReadsEvents() async {
        let source = Source(); source.authorizationStatus = .notDetermined; source.allowed = false
        let importer = CalendarCountdownImporter(source: source)
        await importer.load()
        #expect(source.requested == 1 && source.reads == 0)
        #expect(importer.choices.isEmpty && importer.needsSettings)
    }
    @Test func grantedCalendarImportFiltersPastEventsSearchesAndRecoversFromErrors() async {
        let source = Source(); source.authorizationStatus = .notDetermined
        let store = EKEventStore()
        func event(_ title: String, after seconds: TimeInterval) -> EKEvent {
            let event = EKEvent(eventStore: store)
            event.title = title; event.startDate = Date().addingTimeInterval(seconds)
            event.endDate = event.startDate.addingTimeInterval(3600)
            return event
        }
        source.fixtures = [event("Birthday", after: 7200), event("Old event", after: -3600), event("Meeting", after: 3600)]
        let importer = CalendarCountdownImporter(source: source)
        await importer.load()
        #expect(importer.choices.map(\.title) == ["Meeting", "Birthday"])
        importer.search = "BIRTH"
        #expect(importer.visibleChoices.map(\.title) == ["Birthday"])
        source.failed = true; await importer.load()
        #expect(importer.message != nil && importer.choices.isEmpty && !importer.isLoading)
        source.failed = false; await importer.load()
        #expect(importer.message == nil && importer.choices.count == 2)
    }

    @Test func widgetProjectsNextAnniversaryInsteadOfFinished() {
        let now = date("2026-02-28T09:30:00Z")
        let source = TimerPayload.composeAnnual(label: "Birthday", targetDate: now, timeZone: .gmt, at: now.addingTimeInterval(-60))
        let snapshot = TimerWidgetSnapshot(payload: source, at: now)
        #expect(snapshot.status == .running)
        #expect(snapshot.payload?.endDate == date("2027-02-28T09:30:00Z"))
    }
}
