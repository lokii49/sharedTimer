//
//  TimerHistoryView.swift
//  sharedTimer
//
//  The History screen (1.0.7, mockup D9 · A, https://claude.ai/artifact/EviEMXCXiV8xENfdAN3sAr):
//  finished runs from TimerHistory, grouped by day, newest first, as small muted
//  skies in the colors a run ends on. Run again restarts a timer at its original
//  length or a sequence from phase 1; a yearly countdown offers Open (it has moved
//  on to next year); a one-off countdown's date has passed, so it has no button.
//  Swipe to forget an entry. Opened from the clock button on the Timers toolbar.
//

import SwiftUI

struct TimerHistoryView: View {
    let onRunAgain: (TimerPayload) -> Void
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TimerHistoryEntry] = TimerHistory.all()
    @State private var confirmingClear = false

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
                        ForEach(days, id: \.self) { day in
                            Section {
                                ForEach(entries.filter { Calendar.current.isDate($0.endedAt, inSameDayAs: day) }) { entry in
                                    HistoryRow(entry: entry, action: action(for: entry))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                            Button(role: .destructive) {
                                                TimerHistory.remove(id: entry.id)
                                                entries = TimerHistory.all()
                                            } label: {
                                                Label("Forget", systemImage: "trash")
                                            }
                                            .tint(.red)
                                        }
                                }
                            } header: {
                                Text(dayTitle(day))
                                    .skyLabel()
                                    .foregroundStyle(Sky.roomInk)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Sky.room)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { confirmingClear = true }
                    }
                }
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    TimerHistory.clear()
                    entries = []
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: TimerHistory.changed)) { _ in
                entries = TimerHistory.all()
            }
        }
    }

    private var days: [Date] {
        var seen = Set<Date>()
        return entries.compactMap { entry in
            let day = Calendar.current.startOfDay(for: entry.endedAt)
            return seen.insert(day).inserted ? day : nil
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
                ? .init(title: "Open") { onOpen(entry.timerID); dismiss() }
                : nil
        }
        guard entry.canRunAgain, let payload = entry.runAgainPayload() else { return nil }
        return .init(title: "Run again") { onRunAgain(payload); dismiss() }
    }
}

private struct HistoryRow: View {
    struct Action {
        let title: LocalizedStringKey
        let run: () -> Void
    }

    let entry: TimerHistoryEntry
    let action: Action?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.sequence != nil ? "arrow.triangle.2.circlepath" : entry.kind.symbolName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if entry.sequence != nil { tag("Sequence") }
                    if entry.yearly { tag("Yearly") }
                }
                Text("\(lengthText) · ended \(entry.endedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .opacity(0.85)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.glassPill)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background {
            // The colors the run ended on, toned down: history, not a live sky.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: family.stops(drain: 1), startPoint: .topLeading, endPoint: .bottomTrailing))
                .saturation(0.55)
                .brightness(-0.12)
                .overlay(SkyCornerScrim())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }

    private var family: Sky.Family {
        entry.length < 3600 ? Sky.ember : entry.length < 86_400 ? Sky.dusk : Sky.night
    }

    /// "10 min", or "10 min (8 + 2 added)" when the run was extended.
    private var lengthText: String {
        let total = RecentTimer.lengthText(entry.length)
        guard entry.sequence == nil, entry.kind == .timer, entry.length - entry.duration >= 1 else { return total }
        return String(localized: "\(total) (\(RecentTimer.lengthText(entry.duration)) + \(RecentTimer.lengthText(entry.length - entry.duration)) added)")
    }

    private func tag(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: Capsule())
    }
}
