//
//  TimerStatsView.swift
//  sharedTimer
//
//  N4 · B: the Stats page, pushed from History. Week / Month / All, time by label as
//  bars, streaks, and Export (CSV through the share sheet). Everything comes from
//  TimerStats over TimerHistory's entries — on this iPhone only.
//

import SwiftUI

struct TimerStatsView: View {
    @State private var period = StatsPeriod.week
    @State private var entries: [TimerHistoryEntry] = TimerHistory.all()

    var body: some View {
        let now = Date()
        let shown = TimerStats.entries(entries, in: period, now: now)
        let totals = TimerStats.totals(shown)
        let streaks = TimerStats.streaks(entries, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    // Numbers stand alone with a caption — no "1 runs"/"2 days" built in code
                    // (plurals belong to each language).
                    summaryTile(value: "\(shown.count)", caption: String(localized: "Runs"))
                    summaryTile(value: durationText(TimerStats.totalTime(shown)), caption: String(localized: "Timed"))
                    summaryTile(value: streaks.first.map { "\($0.days)" } ?? "—",
                                caption: String(localized: "Days in a row"))
                }

                if totals.isEmpty {
                    Text("No timers or sequences finished in this period.")
                        .font(.footnote)
                        .foregroundStyle(Sky.roomInk.opacity(0.7))
                } else {
                    Text("Time by name").skyLabel().foregroundStyle(Sky.roomInk)
                    VStack(spacing: 10) {
                        ForEach(totals.prefix(8)) { total in
                            barRow(total, longest: totals.first?.time ?? 1)
                        }
                    }
                }

                if !streaks.isEmpty {
                    Text("Days in a row").skyLabel().foregroundStyle(Sky.roomInk)
                    VStack(spacing: 8) {
                        ForEach(streaks.prefix(5)) { streak in
                            HStack {
                                Text(streak.label).lineLimit(1)
                                Spacer()
                                Text(verbatim: "\(streak.days)").monospacedDigit().foregroundStyle(Sky.roomInk.opacity(0.7))
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Text("From History on this iPhone, which keeps 90 days.")
                    .font(.footnote)
                    .foregroundStyle(Sky.roomInk.opacity(0.6))
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Sky.roomInk)
        .background(Sky.room)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !shown.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: HistoryCSV(text: TimerStats.csv(shown)),
                              preview: SharePreview(String(localized: "Timer history"))) {
                        Text("Export")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TimerHistory.changed)) { _ in
            entries = TimerHistory.all()
        }
    }

    /// "6h 40m", "8m 30s" (the Recent chips' localized units) — not the days-level
    /// `compactSnapshot`, which read "0d" for anything under a day.
    private func durationText(_ time: TimeInterval) -> String {
        time > 0 ? RecentTimer.lengthText(time) : "—"
    }

    private func summaryTile(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(Sky.roomInk.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func barRow(_ total: TimerStats.LabelTotal, longest: TimeInterval) -> some View {
        let fraction = longest > 0 ? total.time / longest : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(total.label).lineLimit(1)
                Spacer()
                Text(durationText(total.time)).monospacedDigit().foregroundStyle(Sky.roomInk.opacity(0.7))
            }
            .font(.subheadline)
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: Sky.dusk.stops(drain: 0.4), startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, proxy.size.width * fraction))
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(localized: "Runs: \(total.runs)"))
    }
}
