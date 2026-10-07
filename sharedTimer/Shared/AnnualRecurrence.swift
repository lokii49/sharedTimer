import Foundation

/// A Gregorian anniversary at a wall-clock time in its original time zone.
/// Leap-day anniversaries use February 28 when the year has no February 29.
struct AnnualRecurrence: Codable, Equatable {
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var timeZoneID: String

    init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        month = parts.month!; day = parts.day!; hour = parts.hour!; minute = parts.minute!; second = parts.second!
        timeZoneID = timeZone.identifier
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return result
    }
    var isValid: Bool {
        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second), timeZoneID.utf8.count <= 128, TimeZone(identifier: timeZoneID) != nil else { return false }
        return (1...[31,29,31,30,31,30,31,31,30,31,30,31][month - 1]).contains(day)
    }
    func year(of date: Date) -> Int { calendar.component(.year, from: date) }

    func date(in year: Int) -> Date? {
        guard isValid, (1...9998).contains(year),
              let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: monthStart),
              let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: min(day, days.count))) else { return nil }
        // nextTime moves a missing spring-forward time to the first valid time;
        // first selects the first occurrence of a repeated autumn time.
        return calendar.nextDate(after: dayStart.addingTimeInterval(-1),
                                 matching: DateComponents(hour: hour, minute: minute, second: second),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    func nextDate(after date: Date) -> Date? {
        let year = year(of: date)
        guard (1...9998).contains(year) else { return nil }
        for candidateYear in year...min(9998, year + 2) {
            if let candidate = self.date(in: candidateYear), candidate > date { return candidate }
        }
        return nil
    }

    private struct Envelope: Codable { let version: Int; let recurrence: AnnualRecurrence }
    static func encode(_ recurrence: AnnualRecurrence) -> Data? {
        guard recurrence.isValid else { return nil }
        return try? JSONEncoder().encode(Envelope(version: 1, recurrence: recurrence))
    }
    static func decode(_ data: Data) -> AnnualRecurrence? {
        guard data.count <= 2048, let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1, value.recurrence.isValid else { return nil }
        return value.recurrence
    }
}

extension TimerPayload {
    /// Clock projection, never a person changing the shared countdown.
    func advancedRecurrence(at date: Date = Date()) -> TimerPayload {
        guard let recurrence, !isPaused, endDate <= date,
              let next = recurrence.nextDate(after: date) else { return self }
        var copy = self
        copy.endDate = next
        copy.duration = max(1, next.timeIntervalSince(date))
        return copy
    }

    /// The selected occurrence plus next year's occurrence, independently armed.
    /// Opening the app refills this bounded window.
    func upcomingAnnualDates(limit: Int = 2, at date: Date = Date()) -> [Date] {
        let current = advancedRecurrence(at: date)
        guard let recurrence, !isPaused, current.endDate > date, limit > 0 else { return [] }
        var result = [current.endDate]
        var boundary = current.endDate
        for _ in 1..<min(limit, 8) {
            guard let next = recurrence.nextDate(after: boundary) else { break }
            result.append(next); boundary = next
        }
        return result
    }

    static func composeAnnual(label: String, targetDate: Date, timeZone: TimeZone = .current,
                              alarmEnabled: Bool = true, vibrationEnabled: Bool = true, at date: Date = Date()) -> TimerPayload {
        let recurrence = AnnualRecurrence(date: targetDate, timeZone: timeZone)
        let end = targetDate > date ? targetDate : (recurrence.nextDate(after: date) ?? targetDate)
        return TimerPayload(id: UUID().uuidString, label: label.isEmpty ? "Countdown" : label,
                            endDate: end, duration: max(1, end.timeIntervalSince(date)), kind: .countdown,
                            alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled,
                            updatedAt: date, recurrence: recurrence)
    }
}
