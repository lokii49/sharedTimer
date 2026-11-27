//
//  TimerStatsView.swift
//  sharedTimer
//
//  N4 · B + redesign pick A (2026-11-27): the Stats page, pushed from History.
//  Week / Month / All; runs and set-for time; set-for time per day as bars; by name;
//  days in a row; Export (all of History as CSV). Everything comes from TimerStats
//  over TimerHistory's entries — on this iPhone only.
//

import Charts
import SwiftUI

struct TimerStatsView: View {
    @State private var period = StatsPeriod.week
    @State private var entries: [TimerHistoryEntry] = TimerHistory.all()

    var body: some View {
        let now = Date()
        let shown = TimerStats.entries(entries, in: period, now: now)
        let timed = shown.filter(TimerStats.isTimed)
        let totals = TimerStats.totals(shown)
        let streaks = TimerStats.streaks(entries, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if timed.isEmpty {
                    // A countdown-only period says so instead of a row of zeros.
                    VStack(spacing: 6) {
                        Text("No timers or sequences finished in this period.")
                        let countdowns = shown.count - timed.count
                        if countdowns > 0 { Text("Countdowns reached: \(countdowns)") }
                    }
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                } else {
                    // "Set for": History keeps the length a run was set for, not how
                    // long it really ran (owner's pick, 2026-11-27).
                    HStack(spacing: 10) {
                        summaryTile(value: "\(timed.count)", caption: String(localized: "Runs"))
                        summaryTile(value: durationText(TimerStats.totalTime(shown)), caption: String(localized: "Set for"))
                    }

                    dayChart(TimerStats.bars(entries, in: period, now: now))

                    Text("By name").skyLabel().foregroundStyle(Sky.roomInk)
                    VStack(spacing: 10) {
                        // Eight names, then the rest together, so the bars add up to the total.
                        ForEach(TimerStats.topWithOther(totals, limit: 8, otherLabel: String(localized: "Other"))) { total in
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

                Text(TimerHistory.dataStart(entries).map {
                    String(localized: "Since \($0.formatted(date: .abbreviated, time: .omitted)) · History keeps 90 days, up to 200 runs.")
                } ?? String(localized: "From History on this iPhone: the last 90 days, up to 200 runs."))
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
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // All of History, whatever period is showing.
                    ShareLink(item: HistoryCSV(text: TimerStats.csv(entries)),
                              preview: SharePreview(String(localized: "Timer history"))) {
                        Text("Export")
                    }
                    .accessibilityIdentifier("exportButton")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TimerHistory.changed)) { _ in
            entries = TimerHistory.all()
        }
    }

    /// Set-for time per day (Week, Month) or per week (All), oldest left. Each bar is
    /// its own VoiceOver element: "Thursday, 27 November: 40m".
    private func dayChart(_ bars: [(start: Date, time: TimeInterval)]) -> some View {
        let weekly = period == .all
        // Whole hours once a bar passes 2 hours, else minutes — so the axis lands on round
        // numbers ("8h", "16h"), never "16h 40m" or a "1s" floor.
        let inHours = (bars.map(\.time).max() ?? 0) >= 2 * 3600
        let scale: Double = inHours ? 3600 : 60
        return Chart(bars, id: \.start) { bar in
            BarMark(x: .value("Day", bar.start, unit: weekly ? .weekOfYear : .day),
                    y: .value("Time", bar.time / scale))
                .foregroundStyle(LinearGradient(colors: Sky.ember.stops(drain: 0.3), startPoint: .top, endPoint: .bottom))
                .cornerRadius(3)
                .accessibilityLabel(weekly ? String(localized: "Week of \(bar.start.formatted(date: .abbreviated, time: .omitted))")
                                           : bar.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(bar.time > 0 ? RecentTimer.lengthText(bar.time) : String(localized: "None"))
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        let whole = Int(amount.rounded())
                        Text(whole == 0 ? "0" : inHours ? String(localized: "\(whole)h", comment: "Compact hours")
                                                        : String(localized: "\(whole)m", comment: "Compact minutes"))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 5)) { _ in
                AxisValueLabel(format: period == .week ? .dateTime.weekday(.narrow) : .dateTime.day().month(.abbreviated))
            }
        }
        // Axis text stops growing at xxLarge (it piled up at accessibility sizes);
        // the bars still read their values to VoiceOver.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(height: 160)
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
