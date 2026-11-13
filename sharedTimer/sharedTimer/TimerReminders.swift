//
//  TimerReminders.swift
//  sharedTimer
//
//  Heads-up reminders before a timer ends (1.0.7, mockup D1 · A): "Halfway",
//  "5 min left", "1 min left" for a timer, "1 day before" / "1 hour before" for a
//  countdown. Plain notifications only — AlarmKit has no mid-run alert.
//
//  A local preference per timer on this iPhone (App Group, never on the wire or in
//  CloudKit), like the alarm tone. Each reminder has its own fixed notification id
//  (`<timer id>.reminder.<kind>`), outside NotificationScheduler's finish slots, so the
//  finish path's cancel (and AlarmController's keep-path) never touches them; they are
//  re-planned by `TimerArming` on every arm, and cancelled on delete.
//
//  Main app only. Mutations made in Messages don't move them until the app next arms
//  the timer — the same limit the AlarmKit alarm has.
//

import SwiftUI
import UserNotifications

enum TimerReminder: String, CaseIterable, Codable, Identifiable {
    case halfway, fiveMinutes, oneMinute, oneDay, oneHour

    var id: String { rawValue }

    static func choices(for kind: TimerKind) -> [TimerReminder] {
        kind == .timer ? [.halfway, .fiveMinutes, .oneMinute] : [.oneDay, .oneHour]
    }

    var title: LocalizedStringKey {
        switch self {
        case .halfway: "Halfway"
        case .fiveMinutes: "5 min left"
        case .oneMinute: "1 min left"
        case .oneDay: "1 day before"
        case .oneHour: "1 hour before"
        }
    }

    /// Notification body — the time left, in words people say.
    var body: String {
        switch self {
        case .halfway: String(localized: "Halfway there")
        case .fiveMinutes: String(localized: "5 minutes left")
        case .oneMinute: String(localized: "1 minute left")
        case .oneDay: String(localized: "1 day to go")
        case .oneHour: String(localized: "1 hour to go")
        }
    }

    private var offset: TimeInterval? {
        switch self {
        case .halfway: nil
        case .fiveMinutes: 300
        case .oneMinute: 60
        case .oneDay: 86_400
        case .oneHour: 3_600
        }
    }

    /// Whether this reminder means anything for a run of `span` seconds — "5 min left"
    /// on a 3-minute timer would fire before it starts.
    func fits(span: TimeInterval) -> Bool {
        guard let offset else { return span >= 60 }
        return span > offset
    }

    /// When it fires for this run, or nil if it doesn't apply (a sequence, paused,
    /// scheduled, or a reminder that doesn't fit).
    func fireDate(for payload: TimerPayload, at date: Date = Date()) -> Date? {
        guard payload.sequence == nil, !payload.isPaused, !payload.isPending(at: date),
              TimerReminder.choices(for: payload.kind).contains(self), fits(span: payload.span) else { return nil }
        let fire = offset.map { payload.endDate.addingTimeInterval(-$0) } ?? payload.endDate.addingTimeInterval(-payload.span / 2)
        return fire > date ? fire : nil
    }
}

enum TimerReminders {
    private static let key = "timerReminders"
    private static let defaults = UserDefaults(suiteName: "group.com.lokesh.sharedTimer")

    static func get(_ timerID: String) -> Set<TimerReminder> {
        let map = defaults?.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set((map[timerID] ?? []).compactMap(TimerReminder.init(rawValue:)))
    }

    static func set(_ reminders: Set<TimerReminder>, for timerID: String) {
        var map = defaults?.dictionary(forKey: key) as? [String: [String]] ?? [:]
        // Prune timers that no longer exist while we're here.
        let stored = Set(TimerStore.loadAll().map(\.id))
        map = map.filter { stored.contains($0.key) }
        map[timerID] = reminders.isEmpty ? nil : reminders.map(\.rawValue).sorted()
        defaults?.set(map, forKey: key)
    }

    static func identifier(_ timerID: String, _ reminder: TimerReminder) -> String {
        "\(timerID).reminder.\(reminder.rawValue)"
    }

    /// Re-plans this timer's reminders for its current run.
    static func sync(_ payload: TimerPayload, at date: Date = Date()) {
        cancel(id: payload.id)
        let center = UNUserNotificationCenter.current()
        for reminder in get(payload.id) {
            guard let fire = reminder.fireDate(for: payload, at: date) else { continue }
            let content = UNMutableNotificationContent()
            content.title = payload.label
            content.body = String(localized: "\(reminder.body) · ends \(payload.endDate.formatted(date: .omitted, time: .shortened))")
            content.sound = .default
            content.userInfo["timerID"] = payload.id
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(date)), repeats: false)
            center.add(UNNotificationRequest(identifier: identifier(payload.id, reminder), content: content, trigger: trigger))
        }
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: TimerReminder.allCases.map { identifier(id, $0) })
    }

    /// Drops pending reminders whose timer is no longer stored — deleted somewhere that
    /// never reached this cancel (a remote delete a Messages pull consumed, say). Run by
    /// the launch/foreground stray sweep (AlarmController.sweepStrayAlarms).
    /// Pending requests are read before the store (same rule as the alarm sweep):
    /// every path saves a timer before planning its reminders, so a reminder in this
    /// snapshot whose timer exists has that timer in the store read after it.
    static func cancelOrphaned() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        guard TimerStore.hasStoredData, let stored = TimerStore.loadAllIfComplete() else { return }
        let storedIDs = Set(stored.map(\.id))
        let orphaned = pending.filter { identifier in
            guard let range = identifier.range(of: ".reminder.", options: .backwards) else { return false }
            return !storedIDs.contains(String(identifier[..<range.lowerBound]))
        }
        if !orphaned.isEmpty { center.removePendingNotificationRequests(withIdentifiers: orphaned) }
    }
}

/// The "Heads-up" chip row for the compose and edit sheets' "When it ends" section.
struct ReminderChips: View {
    let kind: TimerKind
    /// The run these reminders are for — dims ones that don't fit.
    let span: TimeInterval
    @Binding var selection: Set<TimerReminder>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heads-up").font(.subheadline)
            ChipFlowLayout(spacing: 8) {
                ForEach(TimerReminder.choices(for: kind)) { reminder in
                    let on = selection.contains(reminder)
                    let fits = reminder.fits(span: span)
                    Button {
                        if on { selection.remove(reminder) } else { selection.insert(reminder) }
                    } label: {
                        Text(reminder.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? kind.accentColor.opacity(0.85) : .white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!fits)
                    .opacity(fits ? 1 : 0.4)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}
