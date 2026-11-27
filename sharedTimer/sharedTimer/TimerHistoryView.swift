//
//  TimerHistoryView.swift
//  sharedTimer
//
//  The History screen. 1.0.7 (mockup D9 · A) listed every run as a muted sky card;
//  1.0.10 (owner's pick A, https://claude.ai/artifact/UACWYmfb7fzjSVR77LZUim) groups
//  runs of the same timer on the same day (name + kind + length + repeat) into one
//  light row "Pasta ×3", with a round ↻ (Run again: a timer at its length, a sequence
//  from phase 1) or ↗ (Open a yearly countdown still stored). Tap a group for its runs.
//  Swipe → Forget (a group asks first), with a 5 s Undo toast; Clear sits in the ⋯ menu;
//  Stats is a labelled button. Opened from the clock button on the Timers toolbar.
//

import SwiftUI

struct TimerHistoryView: View {
    let onRunAgain: (TimerPayload) -> Void
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TimerHistoryEntry] = TimerHistory.all()
    @State private var confirmingClear = false
    @State private var confirmingForget: TimerHistory.Group?
    /// The runs just forgotten, for the Undo toast (same 5 s as the main list).
    @State private var forgotten: (entries: [TimerHistoryEntry], title: String)?
    @State private var undoTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No history yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Finished timers show up here for 90 days. They stay on this iPhone.")
                    }
                } else {
                    List {
                        ForEach(TimerHistory.grouped(entries), id: \.day) { section in
                            Section {
                                ForEach(section.groups) { group in
                                    groupRow(group)
                                }
                            } header: {
                                Text(dayTitle(section.day))
                                    .skyLabel()
                                    .foregroundStyle(Sky.roomInk)
                            }
                        }
                        if let start = TimerHistory.dataStart(entries) {
                            Text("Since \(start.formatted(date: .abbreviated, time: .omitted)) · History keeps 90 days, up to 200 runs.")
                                .font(.footnote)
                                .foregroundStyle(Sky.roomInk)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Sky.room)
            .overlay(alignment: .bottom) { undoToast }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: TimerHistory.Group.self) { group in
                groupDetail(group)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink {
                            TimerStatsView()
                        } label: {
                            Text("Stats")
                        }
                        .accessibilityIdentifier("statsButton")
                    }
                    // Clear left the toolbar's main capsule, where it sat beside Stats:
                    // a menu item with its confirmation.
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) { confirmingClear = true } label: {
                                Label("Clear History", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel(String(localized: "More"))
                    }
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    TimerHistory.clear()
                    entries = []
                }
            }
            .confirmationDialog(confirmingForget.map { String(localized: "Forget every “\($0.latest.label)” run from this day?") } ?? "",
                                isPresented: Binding(get: { confirmingForget != nil }, set: { if !$0 { confirmingForget = nil } }),
                                titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    if let group = confirmingForget { forget(group.entries) }
                    confirmingForget = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: TimerHistory.changed)) { _ in
                entries = TimerHistory.all()
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: TimerHistory.Group) -> some View {
        let row = HistoryRow(entry: group.latest, count: group.entries.count, action: action(for: group.latest))
        Group {
            if group.entries.count > 1 {
                // Tapping the row opens its runs; the link sits behind it so the row
                // keeps the full width (no system chevron outside the card) and ↻ stays tappable.
                row.background(NavigationLink(value: group) { EmptyView() }.opacity(0))
            } else {
                row
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        // No full swipe: Forget is a tap after the swipe, with Undo after.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                if group.entries.count > 1 { confirmingForget = group } else { forget(group.entries) }
            } label: {
                Label("Forget", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    private func groupDetail(_ group: TimerHistory.Group) -> some View {
        let current = group.entries.filter { run in entries.contains { $0.id == run.id } }
        return List {
            ForEach(current) { entry in
                HistoryRow(entry: entry, action: action(for: entry))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { forget([entry]) } label: {
                            Label("Forget", systemImage: "trash")
                        }
                        .tint(.red)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Sky.room)
        .overlay(alignment: .bottom) { undoToast }
        .navigationTitle(group.latest.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var undoToast: some View {
        if let forgotten {
            HStack(spacing: 14) {
                Text(forgotten.title).lineLimit(1)
                Button("Undo") {
                    TimerHistory.restore(forgotten.entries)
                    self.forgotten = nil
                    undoTask?.cancel()
                }
                .fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func forget(_ runs: [TimerHistoryEntry]) {
        guard let first = runs.first else { return }
        TimerHistory.remove(ids: Set(runs.map(\.id)))
        entries = TimerHistory.all()
        withAnimation { forgotten = (runs, String(localized: "Forgot “\(first.label)”")) }
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { forgotten = nil }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func action(for entry: TimerHistoryEntry) -> HistoryRow.Action? {
        if entry.yearly {
            return TimerStore.loadAll().contains { $0.id == entry.timerID }
                ? .init(title: "Open", systemImage: "arrow.up.forward") { onOpen(entry.timerID); dismiss() }
                : nil
        }
        guard entry.canRunAgain, let payload = entry.runAgainPayload() else { return nil }
        return .init(title: "Run again", systemImage: "arrow.clockwise") { onRunAgain(payload); dismiss() }
    }
}

/// One History row (pick A): a small dot in the colours the run ended on, the name
/// (×n when several runs of the same timer that day fold together), what it was and
/// when, and a round ↻ / ↗ — light, so a busy day isn't a wall of skies.
struct HistoryRow: View {
    struct Action {
        let title: LocalizedStringKey
        var systemImage = "arrow.clockwise"
        let run: () -> Void
    }

    let entry: TimerHistoryEntry
    var count = 1
    let action: Action?
    /// The dot grows with the text, to a point — at the largest sizes a fixed 28 pt dot
    /// was overrun by its own glyph and covered the name.
    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var typeSize

    init(entry: TimerHistoryEntry, count: Int = 1, action: Action?) {
        self.entry = entry
        self.count = count
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: family.stops(drain: 1), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: min(dotSize, 44), height: min(dotSize, 44))
                .overlay(Image(systemName: symbol).font(.system(size: min(dotSize, 44) * 0.45, weight: .semibold)).foregroundStyle(.white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(count > 1 ? "\(entry.label) ×\(count)" : entry.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    if let repeatTag = entry.repeatTag { pill(repeatTag) }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action: action.run) {
                    Image(systemName: action.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(Text(action.title))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        entry.sequence != nil ? "arrow.triangle.2.circlepath" : entry.kind.symbolName
    }

    private var family: Sky.Family {
        entry.length < 3600 ? Sky.ember : entry.length < 86_400 ? Sky.dusk : Sky.night
    }

    private var time: String { entry.endedAt.formatted(date: .omitted, time: .shortened) }

    private var subtitle: String {
        // No "4 phases" (an English plural built in code): the sequence's length instead.
        if entry.sequence != nil {
            return count > 1
                ? String(localized: "Sequence · \(lengthText) · last \(time)")
                : String(localized: "Sequence · \(lengthText) · \(time)")
        }
        if entry.kind == .countdown { return String(localized: "Countdown · reached \(time)") }
        return count > 1 ? String(localized: "\(lengthText) each · last \(time)") : String(localized: "\(lengthText) · ended \(time)")
    }

    private var accessibilityText: String {
        count > 1
            ? String(localized: "\(entry.label), \(subtitle), runs: \(count)")
            : String(localized: "\(entry.label), \(subtitle)")
    }

    /// "10 min", or "10 min (8 + 2 added)" when the run was extended.
    private var lengthText: String {
        let total = RecentTimer.lengthText(entry.length)
        guard entry.sequence == nil, entry.kind == .timer, entry.length - entry.duration >= 1 else { return total }
        return String(localized: "\(total) (\(RecentTimer.lengthText(entry.duration)) + \(RecentTimer.lengthText(entry.length - entry.duration)) added)")
    }

    /// Not named `tag`: inside a View that name can resolve to SwiftUI's `View.tag(_:)`,
    /// which nested the row inside itself without end — History crashed (stack
    /// overflow) as soon as a sequence or repeating-countdown run was on screen (1.0.9).
    private func pill(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: Capsule())
    }
}
