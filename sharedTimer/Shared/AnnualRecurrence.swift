import Foundation

/// A repeating countdown at a wall-clock time in its original time zone. Yearly
/// (the original 1.0.4 anniversary) by default; since 1.0.7 also daily, weekly (on
/// `weekday`) and monthly (on `day`). Leap-day anniversaries use February 28 when
/// the year has no February 29; a monthly day 29–31 uses the month's last day.
///
/// Wire: yearly travels exactly as before (`annual` link param, `recurrenceData`
/// CloudKit field), so older apps read it unchanged. Daily/weekly/monthly use a new
/// `repeat` param and `repeatRuleData` field — older apps ignore both and show a
/// one-off countdown, instead of misreading the rule as yearly.
struct AnnualRecurrence: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case daily, weekly, monthly, yearly
        var id: String { rawValue }
    }

    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var timeZoneID: String
    var frequency: Frequency = .yearly
    /// Gregorian weekday (1 = Sunday … 7 = Saturday), weekly only.
    var weekday: Int?

    // Hand-written so a field added later can default instead of failing the decode
    // (a nested failure drops the whole TimerPayload). New fields: `decodeIfPresent` +
    // default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decode(Int.self, forKey: .month)
        day = try container.decode(Int.self, forKey: .day)
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 0
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        second = try container.decodeIfPresent(Int.self, forKey: .second) ?? 0
        timeZoneID = try container.decode(String.self, forKey: .timeZoneID)
        frequency = (try? container.decodeIfPresent(Frequency.self, forKey: .frequency)) ?? .yearly
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday)
    }

    init(date: Date, timeZone: TimeZone = .current, frequency: Frequency = .yearly) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second, .weekday], from: date)
        month = parts.month!; day = parts.day!; hour = parts.hour!; minute = parts.minute!; second = parts.second!
        timeZoneID = timeZone.identifier
        self.frequency = frequency
        weekday = frequency == .weekly ? parts.weekday : nil
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return result
    }
    var isValid: Bool {
        guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second), timeZoneID.utf8.count <= 128, TimeZone(identifier: timeZoneID) != nil else { return false }
        if frequency == .weekly, !(1...7).contains(weekday ?? 0) { return false }
        return (1...[31,29,31,30,31,30,31,31,30,31,30,31][month - 1]).contains(day)
    }
    func year(of date: Date) -> Int { calendar.component(.year, from: date) }

    func date(in year: Int) -> Date? { date(year: year, month: month) }

    /// This rule's day (clamped to the month's length) and time in a given month.
    private func date(year: Int, month: Int) -> Date? {
        guard isValid, (1...9998).contains(year),
              let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
        return wallTime(year: year, month: month, day: min(day, days.count))
    }

    /// The rule's time on one local day: the first copy of a repeated autumn time, or
    /// the first valid time after a missing spring one — the web page's rule.
    /// `Calendar.nextDate(.nextTime, .first)` gets whole-hour gaps right but not others:
    /// Lord Howe's 30-minute gap moved 02:15 to the *next day*, Chatham's 02:45 gap gave
    /// 04:00 for 02:50 instead of 03:45. A result that isn't the rule's exact wall time
    /// on that day is redone minute by minute from the rule's time (seconds dropped
    /// after the first minute), keeping the earliest instant that exists.
    private func wallTime(year: Int, month: Int, day: Int) -> Date? {
        guard let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        if let exact = calendar.nextDate(after: dayStart.addingTimeInterval(-1),
                                         matching: DateComponents(hour: hour, minute: minute, second: second),
                                         matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: exact)
            if parts.year == year, parts.month == month, parts.day == day,
               parts.hour == hour, parts.minute == minute, parts.second == second { return exact }
        }
        var wallClock = Calendar(identifier: .gregorian)
        wallClock.timeZone = .gmt
        guard let nominal = wallClock.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else { return nil }
        for offset in 0...180 {
            let wall = nominal.addingTimeInterval(TimeInterval(offset * 60 - (offset == 0 ? 0 : second)))
            let parts = wallClock.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
            guard let candidate = calendar.date(from: parts) else { continue }
            if calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate) == parts { return candidate }
        }
        return nil
    }

    /// Daily/weekly, day by day like the web page. A day's occurrence is its first copy
    /// only: searching from *inside* an autumn repeated hour used to return that
    /// night's second copy (a 01:30 daily repeat rang twice), and a non-whole-hour
    /// spring gap used to skip the day entirely.
    private func nextDailyOrWeekly(after date: Date) -> Date? {
        let start = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if frequency == .weekly, calendar.component(.weekday, from: day) != weekday { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            if let time = wallTime(year: y, month: m, day: d), time > date { return time }
        }
        return nil
    }

    func nextDate(after date: Date) -> Date? {
        let year = year(of: date)
        guard isValid, (1...9998).contains(year) else { return nil }
        switch frequency {
        case .yearly:
            for candidateYear in year...min(9998, year + 2) {
                if let candidate = self.date(in: candidateYear), candidate > date { return candidate }
            }
            return nil
        case .daily, .weekly:
            return nextDailyOrWeekly(after: date)
        case .monthly:
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard var y = parts.year, var m = parts.month else { return nil }
            for _ in 0..<3 {
                if let candidate = self.date(year: y, month: m), candidate > date { return candidate }
                m += 1
                if m > 12 { m = 1; y += 1 }
            }
            return nil
        }
    }

    /// The same rule at another frequency, anchored on `date` (weekday from it).
    func with(frequency: Frequency, anchoredOn date: Date) -> AnnualRecurrence {
        AnnualRecurrence(date: date, timeZone: TimeZone(identifier: timeZoneID) ?? .current, frequency: frequency)
    }

    private struct Envelope: Codable { let version: Int; let recurrence: AnnualRecurrence }
    /// Yearly only (`annual` / `recurrenceData`), so an older app never reads a daily or
    /// weekly rule as an anniversary.
    static func encode(_ recurrence: AnnualRecurrence) -> Data? {
        guard recurrence.isValid, recurrence.frequency == .yearly else { return nil }
        return try? JSONEncoder().encode(Envelope(version: 1, recurrence: recurrence))
    }
    /// Always yearly, whatever a hand-made envelope says.
    static func decode(_ data: Data) -> AnnualRecurrence? {
        guard data.count <= 2048, let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1 else { return nil }
        var recurrence = value.recurrence
        recurrence.frequency = .yearly
        recurrence.weekday = nil
        return recurrence.isValid ? recurrence : nil
    }

    /// Daily/weekly/monthly (`repeat` link param / `repeatRuleData`, 1.0.7).
    static func encodeRepeat(_ recurrence: AnnualRecurrence) -> Data? {
        guard recurrence.isValid, recurrence.frequency != .yearly else { return nil }
        return try? JSONEncoder().encode(Envelope(version: 1, recurrence: recurrence))
    }
    static func decodeRepeat(_ data: Data) -> AnnualRecurrence? {
        guard data.count <= 2048, let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.version == 1, value.recurrence.frequency != .yearly, value.recurrence.isValid else { return nil }
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

    static func composeAnnual(label: String, targetDate: Date, timeZone: TimeZone = .current, frequency: AnnualRecurrence.Frequency = .yearly,
                              alarmEnabled: Bool = true, vibrationEnabled: Bool = true, at date: Date = Date()) -> TimerPayload {
        let recurrence = AnnualRecurrence(date: targetDate, timeZone: timeZone, frequency: frequency)
        let end = targetDate > date ? targetDate : (recurrence.nextDate(after: date) ?? targetDate)
        // Same rules as `compose`: trimmed, and the default in the person's language.
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimerPayload(id: UUID().uuidString, label: trimmed.isEmpty ? String(localized: "Countdown") : trimmed,
                            endDate: end, duration: max(1, end.timeIntervalSince(date)), kind: .countdown,
                            alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled,
                            updatedAt: date, recurrence: recurrence)
    }
}

extension AnnualRecurrence.Frequency {
    /// "Repeats weekly" — detail screens in the app, Messages and the App Clip.
    var repeatsCaption: LocalizedStringResource {
        switch self {
        case .daily: "Repeats daily"
        case .weekly: "Repeats weekly"
        case .monthly: "Repeats monthly"
        case .yearly: "Repeats yearly"
        }
    }

    /// The skip-ahead button: detail screen and the full-screen alarm.
    var nextTitle: LocalizedStringResource {
        switch self {
        case .daily: "Next Day"
        case .weekly: "Next Week"
        case .monthly: "Next Month"
        case .yearly: "Next Year"
        }
    }

    /// The compose sheet's Repeat choice.
    var pickerTitle: LocalizedStringResource {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}
