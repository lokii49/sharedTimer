//
//  SharedTimerWidget.swift
//  sharedTimerWidget
//

import WidgetKit
import SwiftUI
import AppIntents

struct TimerEntry: TimelineEntry {
    let date: Date
    let payload: TimerPayload?

    /// Smart Stack / Smart Rotate: a timer about to finish first, then running ones.
    var relevance: TimelineEntryRelevance? {
        let snapshot = TimerWidgetSnapshot(payload: payload, at: date)
        switch snapshot.status {
        case .running: return TimelineEntryRelevance(score: snapshot.remaining <= 3600 ? 100 : 50, duration: snapshot.remaining)
        case .scheduled: return TimelineEntryRelevance(score: 20)
        case .paused: return TimelineEntryRelevance(score: 10)
        case .finished, .empty: return TimelineEntryRelevance(score: 0)
        }
    }

    /// What the widget gallery shows before anyone has a timer.
    static var sample: TimerEntry {
        TimerEntry(date: .now, payload: TimerPayload(label: String(localized: "Coffee break"), duration: 300))
    }
}

// MARK: - Live remaining text

/// The countdown value for widget surfaces. Under a day it's a system-rendered
/// `Text(timerInterval:)`, which WidgetKit ticks every second for free — a widget
/// snapshot can't re-render itself, so any hand-formatted string would freeze between
/// timeline refreshes. Coarser values render static, honest strings ("3d 4h", "1mo 8d")
/// rather than fake ticking seconds; a paused value is frozen anyway.
///
/// `Text(timerInterval:)` claims all the width it's offered, so trailing-aligned uses
/// must cap it with an explicit frame.
/// `date`: the timeline entry's date — a precomputed entry renders the state at its
/// own moment, not whenever WidgetKit happened to build the view.
@ViewBuilder
func remainingText(endDate: Date, pausedRemaining: TimeInterval?, at date: Date = .now) -> some View {
    let remaining = max(0, endDate.timeIntervalSince(date))
    if pausedRemaining == nil && remaining > 0 && remaining < 86400 {
        Text(timerInterval: date...max(date, endDate), countsDown: true)
    } else {
        Text(staticRemainingString(endDate: endDate, pausedRemaining: pausedRemaining, at: date))
    }
}

/// Home-screen digits: a scheduled sequence shows its start time ("Tomorrow 7:00 AM"),
/// like SkyCard and the Lock Screen widget — not a countdown to the end of phase 0.
@ViewBuilder
func pendingAwareRemaining(_ payload: TimerPayload, at date: Date = .now) -> some View {
    if payload.isPending(at: date), let start = payload.scheduledStartDate {
        Text(Sky.pendingStartText(for: start, at: date))
    } else {
        remainingText(endDate: payload.endDate, pausedRemaining: payload.pausedRemaining, at: date)
    }
}

func staticRemainingString(endDate: Date, pausedRemaining: TimeInterval?, at date: Date = .now) -> String {
    if let pausedRemaining {
        return TimeFormat.display(pausedRemaining)
    }
    let remaining = max(0, endDate.timeIntervalSince(date))
    if remaining <= 0 {
        return "00:00"
    }
    if remaining >= TimeFormat.calendarThreshold {
        return TimeFormat.calendarBreakdown(remaining)
    }
    return TimeFormat.daysHours(remaining)
}

// MARK: - Configurable single-timer widget

struct SelectTimerIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Timer"
    static var description = IntentDescription("Pick which timer or countdown this widget shows.")

    @Parameter(title: "Timer")
    var timer: TimerChoice?
}

struct ConfigurableTimerProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TimerEntry { .sample }

    func snapshot(for configuration: SelectTimerIntent, in context: Context) async -> TimerEntry {
        let date = Date()
        let payload = resolve(configuration, at: date)
        // The gallery shows an example instead of "No Timers" to someone with none yet.
        if context.isPreview && payload == nil { return .sample }
        return TimerEntry(date: date, payload: payload)
    }

    /// Precomputed entries at each state boundary (start, phase changes, finish) plus
    /// sky-drain and hour-rollover steps, so nothing waits for a reload; see
    /// `TimerWidgetSnapshot.homeTimeline`.
    func timeline(for configuration: SelectTimerIntent, in context: Context) async -> Timeline<TimerEntry> {
        let date = Date()
        let snapshots = TimerWidgetSnapshot.homeTimeline(payload: resolve(configuration, at: date), at: date)
        return Timeline(entries: snapshots.map { TimerEntry(date: $0.date, payload: $0.payload) },
                        policy: TimerWidgetSnapshot.reloadPolicy(for: snapshots))
    }

    /// A configured timer is shown as-is (even paused or just-finished) — the user picked
    /// it specifically. Unconfigured (or deleted): the timer last acted on from a
    /// widget/Live Activity button while it's paused/running or finished within the last
    /// hour (so Resume/Repeat stay where the user tapped); else the soonest running
    /// timer; else the soonest paused one. Same rule as the Lock Screen widget.
    private func resolve(_ configuration: SelectTimerIntent, at date: Date) -> TimerPayload? {
        TimerWidgetSnapshot.resolve(from: TimerStore.loadAll(), selectedID: configuration.timer?.id,
                                    focusID: TimerStore.widgetFocusID, at: date)
    }
}

struct BigCountdownWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    let payload: TimerPayload?
    /// The entry's date: every state below is read at it, not at render time.
    var date: Date = .now

    /// StandBy strips whatever `.containerBackground` supplies and substitutes plain
    /// system black — this widget's entire identity is that background, so it has to be
    /// redrawn as ordinary content there. Skipped in `.vibrant` (StandBy Night Mode / Lock
    /// Screen): the system desaturates everything by luminance in that mode, and a
    /// colorful gradient underneath fights that rather than helping it.
    private var needsStandBySkyLayer: Bool {
        !showsWidgetContainerBackground && widgetRenderingMode == .fullColor
    }

    var body: some View {
        ZStack {
            if needsStandBySkyLayer {
                if let payload {
                    Sky.gradient(for: payload, at: date)
                    SkyCornerScrim()
                } else {
                    Sky.room
                }
            }
            Group {
                if let payload {
                    content(for: payload)
                } else {
                    emptyView
                }
            }
        }
        // Tapping opens that timer's details (ID only — a stale widget never imports
        // a snapshot); before 1.0.9 it just opened the app wherever it was.
        .widgetURL(payload.map { TimerAppLink.url(for: $0.id) })
        .containerBackground(for: .widget) {
            // The widget IS the timer's sky, edge to edge. The sky is fixed artwork — all
            // text on it is white, so nothing here needs to adapt to Light/Dark Mode. This
            // is ignored in StandBy — see needsStandBySkyLayer above.
            if let payload {
                // C6: scrim under the footer text on the sky's bright corner.
                ZStack {
                    Sky.gradient(for: payload, at: date)
                    SkyCornerScrim()
                }
            } else {
                Sky.room
            }
        }
    }

    private var isSmall: Bool { family == .systemSmall }

    private func content(for payload: TimerPayload) -> some View {
        let status = TimerWidgetSnapshot(payload: payload, at: date).status
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(payload.label)
                    .skyLabel(isSmall ? 10 : 11)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if status == .paused {
                    Text("Paused").skyLabel(isSmall ? 9 : 10)
                } else if status == .finished {
                    Text("Time's up").skyLabel(isSmall ? 9 : 10)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            Spacer(minLength: 0)

            pendingAwareRemaining(payload, at: date)
                // Shimmers while a tapped button's update is in flight (pause/resume
                // only lands after the app runs the intent and the timeline reloads).
                .invalidatableContent()
                .font(.system(size: isSmall ? 34 : 46, weight: .regular))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.white)
                // Tinted / clear Home Screen: the digits take the accent (owner's pick A).
                .widgetAccentable()

            if isSmall {
                // Small: the buttons take the footer's place.
                WidgetTimerControls(payload: payload, date: date, size: 34)
                    .padding(.top, 4)
            } else {
                HStack(alignment: .center) {
                    Text(footerText(for: payload))
                        .skyLabel(10.5)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    WidgetTimerControls(payload: payload, date: date, size: 36)
                }
            }
        }
        .padding(isSmall ? 2 : 4)
    }

    /// Same line SkyCard shows (localized there).
    private func footerText(for payload: TimerPayload) -> String {
        Sky.endText(for: payload, at: date)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(Sky.roomInk)
            Text("No Timers")
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SharedTimerCountdownWidget: Widget {
    let kind = "SharedTimerCountdownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectTimerIntent.self, provider: ConfigurableTimerProvider()) { entry in
            BigCountdownWidgetView(payload: entry.payload, date: entry.date)
        }
        .configurationDisplayName("Single Timer")
        .description("Pick one timer or countdown to show big, on its own.")
        .supportedFamilies([.systemSmall, .systemMedium])
        // Owner's pick (1.0.9): not in CarPlay — its 9–10 pt labels and two buttons aren't
        // for driving; the Live Activity's small tile already shows a running timer there.
        .disfavoredLocations([.carPlay], for: [.systemSmall])
    }
}

// MARK: - All-timers list widget

struct TimerListEntry: TimelineEntry {
    let date: Date
    let payloads: [TimerPayload]

    var relevance: TimelineEntryRelevance? {
        guard let soonest = payloads.first(where: { !$0.isPaused }) else { return TimelineEntryRelevance(score: payloads.isEmpty ? 0 : 10) }
        let left = soonest.endDate.timeIntervalSince(date)
        return TimelineEntryRelevance(score: left <= 3600 ? 100 : 50, duration: max(0, left))
    }
}

struct TimerListProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimerListEntry {
        TimerListEntry(date: .now, payloads: [TimerEntry.sample.payload!])
    }

    func getSnapshot(in context: Context, completion: @escaping (TimerListEntry) -> Void) {
        let date = Date()
        let payloads = Self.active(in: TimerStore.loadAll(), at: date)
        if context.isPreview && payloads.isEmpty { return completion(placeholder(in: context)) }
        completion(TimerListEntry(date: date, payloads: payloads))
    }

    /// An entry at every listed timer's own boundaries (finish, phase change, start), so
    /// a finished timer leaves the list and a sequence shows its next phase without a
    /// reload. Reloads only for what entries can't cover (coarse day text past the last
    /// entry), else the slow idle fallback.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TimerListEntry>) -> Void) {
        let date = Date()
        let stored = TimerStore.loadAll()
        let listed = Self.active(in: stored, at: date)
        let dates = TimerWidgetSnapshot.listDates(for: listed, at: date)
        let entries = dates.map { TimerListEntry(date: $0, payloads: Self.active(in: stored, at: $0)) }
        let reload = TimerWidgetSnapshot.listReloadDate(for: listed, dates: dates, at: date)
        completion(Timeline(entries: entries, policy: .after(reload)))
    }

    /// Unfinished timers at `date`, soonest first. `advancedSequence(at:)` first (pure,
    /// no-op for a plain payload): the raw stored endDate of a sequence on a stale phase,
    /// or a repeating countdown's passed occurrence, would read as expired.
    static func active(in stored: [TimerPayload], at date: Date) -> [TimerPayload] {
        stored
            .map { $0.advancedSequence(at: date) }
            .filter { TimerWidgetSnapshot(payload: $0, at: date).status != .finished }
            .sorted { $0.endDate < $1.endDate }
    }
}

struct TimerListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsWidgetContainerBackground
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    let entry: TimerListEntry

    private var maxRows: Int { family == .systemLarge ? 5 : 2 }

    /// Tinted / clear Home Screen (`.accented`) and StandBy night (`.vibrant`) draw by
    /// opacity or brightness only, so an opaque sky fill under white text became one
    /// slab of tint. There the rows are outlined instead (owner's pick A, 2026-11-27).
    private var outlined: Bool { widgetRenderingMode != .fullColor }

    /// See BigCountdownWidgetView's needsStandBySkyLayer — same StandBy mechanism, lower
    /// stakes here since each row already paints its own gradient as regular content, not
    /// through containerBackground, so only the near-black outer backdrop is at risk.
    private var needsStandBySkyLayer: Bool {
        !showsWidgetContainerBackground && widgetRenderingMode == .fullColor
    }

    var body: some View {
        ZStack {
            if needsStandBySkyLayer {
                Sky.room
            }
            Group {
                if entry.payloads.isEmpty {
                    emptyView
                } else if family == .systemExtraLarge {
                    grid
                } else {
                    // As many rows as fit with the "N more…" line: two rows plus that line
                    // overflowed a medium widget, five a large one on smaller phones.
                    ViewThatFits(in: .vertical) {
                        rows(limit: maxRows)
                        rows(limit: maxRows - 1)
                        rows(limit: max(1, maxRows - 2))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        // The dark room, fixed — each row hangs in it as its own small sky. Ignored in
        // StandBy — see needsStandBySkyLayer above.
        .containerBackground(Sky.room, for: .widget)
    }

    private func rows(limit: Int) -> some View {
        VStack(spacing: 7) {
            ForEach(Array(entry.payloads.prefix(limit))) { payload in
                // Fixed row height, stack pinned to the top — with a single timer
                // the row must not stretch and drift to the vertical center.
                row(payload)
                    .frame(height: 54)
            }
            if entry.payloads.count > limit {
                Text("\(entry.payloads.count - limit) more…")
                    .font(.caption2)
                    .foregroundStyle(Sky.roomInk)
            }
        }
    }

    /// A miniature sky card: label and end info on the left, live remaining time on the
    /// right. The live text claims all offered width, so it's capped. Tapping the card
    /// (not its Pause button) opens that timer.
    private func row(_ payload: TimerPayload) -> some View {
        HStack(spacing: 10) {
            Link(destination: TimerAppLink.url(for: payload.id)) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(payload.label)
                            .skyLabel(10)
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(outlined ? 0.75 : 0.9))
                        Text(Sky.endText(for: payload, at: entry.date))
                            .skyLabel(9.5)
                            .foregroundStyle(.white.opacity(outlined ? 0.6 : 0.8))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    pendingAwareRemaining(payload, at: entry.date)
                        // Shimmers while a tapped button's update is in flight (pause/resume
                        // only lands after the app runs the intent and the timeline reloads).
                        .invalidatableContent()
                        .font(.system(size: 22, weight: .medium))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.white)
                        .widgetAccentable()
                        .frame(maxWidth: 92, alignment: .trailing)
                }
            }

            // Pause/Resume only — no Stop on the list, so it can't be mis-tapped.
            if !payload.isPending(at: entry.date) && !TimerStore.isReadOnly(id: payload.id) {
                PauseToggle(timerID: payload.id, isPaused: payload.isPaused, size: 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { cardBackground(for: payload, cornerRadius: 14) }
    }

    /// The row/card's sky, with the C6 corner scrim under its small text — or, in tinted
    /// and night modes, a hairline outline.
    @ViewBuilder
    private func cardBackground(for payload: TimerPayload, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if outlined {
            shape.strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
        } else {
            ZStack {
                Sky.gradient(for: payload, at: entry.date)
                SkyCornerScrim()
            }
            .clipShape(shape)
        }
    }

    // MARK: iPad extra large (owner's pick A: a grid of sky cards)

    private var grid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Array(entry.payloads.prefix(6))) { payload in
                    card(payload)
                        .frame(height: 150)
                }
            }
            if entry.payloads.count > 6 {
                Text("\(entry.payloads.count - 6) more…")
                    .font(.caption2)
                    .foregroundStyle(Sky.roomInk)
            }
        }
    }

    /// One timer as its own small sky: name top, big time bottom, Pause on the corner.
    /// The card opens the timer; the button only pauses.
    private func card(_ payload: TimerPayload) -> some View {
        ZStack(alignment: .topTrailing) {
            Link(destination: TimerAppLink.url(for: payload.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.label)
                        .skyLabel(10)
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(outlined ? 0.75 : 0.9))
                        .padding(.trailing, 36)
                    Text(Sky.endText(for: payload, at: entry.date))
                        .skyLabel(9.5)
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(outlined ? 0.6 : 0.8))
                    Spacer(minLength: 0)
                    pendingAwareRemaining(payload, at: entry.date)
                        .invalidatableContent()
                        .font(.system(size: 32, weight: .regular))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .widgetAccentable()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(12)
            }
            if !payload.isPending(at: entry.date) && !TimerStore.isReadOnly(id: payload.id) {
                PauseToggle(timerID: payload.id, isPaused: payload.isPaused, size: 28)
                    .padding(8)
            }
        }
        .background { cardBackground(for: payload, cornerRadius: 16) }
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(Sky.roomInk)
            Text("No Timers")
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The default widget — same `kind` as before, so it updates in place on home screens
/// that already have it placed rather than requiring a re-add.
struct SharedTimerWidget: Widget {
    let kind = "SharedTimerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimerListProvider()) { entry in
            TimerListWidgetView(entry: entry)
        }
        .configurationDisplayName("All Timers")
        .description("Lists every active timer and countdown, soonest first.")
        // Extra large: iPad only (owner's pick A, a grid of up to six sky cards).
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}
