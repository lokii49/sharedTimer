//
//  WhatsNew.swift
//  sharedTimer
//

import SwiftUI

/// Once-per-update "What's New" tour. 1.0.5 is "Afternoon Walk" (direction A of three
/// mockups, chosen 2026-10-18, https://claude.ai/artifact/N3mZkpafHZnp2gt9rADTnz): the
/// 1.0.4 "Sunrise Walk" ended at sunrise, so this one carries on through the day — the
/// sky runs from dusk's pale day end into the ember evening, a little more per page.
/// Main app only; also reachable any time from Settings → What's New → Replay.
enum WhatsNew {
    /// The version whose features the pages below describe. Bump it (and the pages)
    /// when a later release gets its own tour; a release without one shows nothing.
    static let contentVersion = "1.0.10"
    static let seenVersionKey = "whatsNewSeenVersion"
    /// UI tests and screenshots: present regardless of the stored version.
    static let forceShowArgument = "-ShowWhatsNew"

    /// Pure gate. Shows only to people updating into a version that has a tour:
    /// never on a fresh install (nothing to compare against; the empty state already
    /// explains the app), and never twice for the same tour. A pre-1.0.4 install
    /// never stored a seen version, so `isExistingInstall` (it has stored timer data)
    /// is what tells an update from a fresh install the first time.
    static func shouldShow(seenVersion: String?, currentVersion: String, isExistingInstall: Bool) -> Bool {
        guard compare(currentVersion, contentVersion) != .orderedAscending else { return false }
        if let seenVersion { return compare(seenVersion, contentVersion) == .orderedAscending }
        return isExistingInstall
    }

    /// Numeric dotted-version comparison ("1.0.10" > "1.0.9"); missing parts are 0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Decides once per launch and records the current version as seen right away —
    /// at most one showing per update even if the app is killed mid-tour.
    static func consumeLaunchPresentation(defaults: UserDefaults = .standard) -> Bool {
        if ProcessInfo.processInfo.arguments.contains(forceShowArgument) { return true }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let show = shouldShow(seenVersion: defaults.string(forKey: seenVersionKey),
                              currentVersion: current,
                              // Data the Clip or Messages wrote before the app was ever
                              // installed isn't an update.
                              isExistingInstall: TimerStore.hasStoredData && !TimerStore.wasCreatedOutsideApp)
        defaults.set(current, forKey: seenVersionKey)
        return show
    }

    struct Feature: Identifiable {
        let id: Int
        let title: String
        let body: String
    }

    /// 1.0.10 lineup A (owner's pick 2026-11-28, https://claude.ai/artifact/DstXtpzgtHHLtfAVJLQDXe):
    /// only claims already seen working. Spoken cues and the − button are in the
    /// release notes instead.
    static let features: [Feature] = [
        Feature(id: 0, title: String(localized: "Tags and notes"),
                body: String(localized: "Tag timers like Kitchen or Work and filter the list. Add a note, such as “Turn at half time”, and it comes back the next time you start that timer.")),
        Feature(id: 1, title: String(localized: "Stats"),
                body: String(localized: "History now groups repeat runs, and a Stats page shows your week, month and streaks. Export it all as a spreadsheet.")),
        Feature(id: 2, title: String(localized: "Test my alarm"),
                body: String(localized: "In Settings, ring a real alarm in five seconds to make sure it gets through. If it doesn't, Timer shows what to change.")),
        Feature(id: 3, title: String(localized: "More in Messages"),
                body: String(localized: "Edit a timer, start one of your saved sequences, make a countdown repeat, and undo a removal, all from Messages."))
    ]
}

struct WhatsNewView: View {
    let onDone: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var features: [WhatsNew.Feature] { WhatsNew.features }
    private var isLast: Bool { page == features.count - 1 }

    /// Afternoon into evening: dusk's drained (day) end blending into a fresh ember sky,
    /// eased like a timer's own drain — the tour ends at sunset.
    private func skyColors(_ index: Int) -> [Color] {
        let t = Double(index) / Double(max(1, features.count - 1))
        return zip(Sky.dusk.drained, Sky.ember.fresh).map { $0.mixed(toward: $1, by: t * t).color }
    }

    var body: some View {
        ZStack {
            ForEach(features) { feature in
                LinearGradient(colors: skyColors(feature.id), startPoint: .top, endPoint: .bottom)
                    .opacity(feature.id == page ? 1 : 0)
            }
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: page)

            // The early pages are bright daytime sky (pale peach at the bottom); soft top and
            // bottom scrims keep the white text and the Continue pill readable.
            LinearGradient(stops: [.init(color: .black.opacity(0.32), location: 0),
                                   .init(color: .black.opacity(0), location: 0.45),
                                   .init(color: .black.opacity(0), location: 0.6),
                                   .init(color: .black.opacity(0.3), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button("Skip") { onDone() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .opacity(isLast ? 0 : 1)
                        .disabled(isLast)
                }
                .padding(.horizontal, 22)

                TabView(selection: $page) {
                    ForEach(features) { feature in
                        WhatsNewPage(feature: feature, count: features.count, isActive: feature.id == page)
                            .tag(feature.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(features) { feature in
                        Capsule()
                            .fill(.white.opacity(feature.id == page ? 1 : 0.35))
                            .frame(width: feature.id == page ? 20 : 7, height: 7)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: page)
                .accessibilityElement()
                .accessibilityLabel("Page \(page + 1) of \(features.count)")

                Button(isLast ? "Start" : "Continue") {
                    if isLast {
                        onDone()
                    } else if reduceMotion {
                        page += 1
                    } else {
                        withAnimation(.easeInOut(duration: 0.35)) { page += 1 }
                    }
                }
                .buttonStyle(.glassPill)
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

private struct WhatsNewPage: View {
    let feature: WhatsNew.Feature
    let count: Int
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New in \(WhatsNew.contentVersion) · \(feature.id + 1) of \(count)")
                .skyLabel(11)
                .foregroundStyle(.white.opacity(0.7))
            Text(feature.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(feature.body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            ScaledIllustration(index: feature.id, isActive: isActive)
                .accessibilityHidden(true)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 26)
    }
}

// MARK: - Illustrations

/// Each illustration is a pure function of its loop position `t` (0..<1), driven by a
/// TimelineView only while its page is on screen. Reduce Motion pins `t` to the
/// frame that best shows the finished feature, and nothing moves.
private struct WhatsNewIllustration: View {
    let index: Int
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var period: Double { [6, 5, 6, 7][index] }
    private var restingT: Double { [0.85, 0.8, 0.85, 0.9][index] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? restingT : (seconds.truncatingRemainder(dividingBy: period)) / period
            Group {
                switch index {
                case 0: TagsScene(t: t)
                case 1: StatsScene(t: t)
                case 2: TestAlarmScene(t: t)
                default: MessagesParityScene(t: t)
                }
            }
            .frame(width: 260, height: 210)
        }
    }
}

/// Illustrations are drawn at a fixed 260×210 design size, then enlarged up to 1.3× —
/// less on narrow phones (an SE has ~323pt of content width), never overflowing.
private struct ScaledIllustration: View {
    let index: Int
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = min(1.3, geo.size.width / 260)
            WhatsNewIllustration(index: index, isActive: isActive)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 273)
    }
}

/// 0→1 across [start, end], clamped.
private func ramp(_ t: Double, _ start: Double, _ end: Double) -> Double {
    min(1, max(0, (t - start) / (end - start)))
}

/// Fades in over [inStart, inEnd] and out over [outStart, outEnd].
private func pulse(_ t: Double, _ inStart: Double, _ inEnd: Double, _ outStart: Double, _ outEnd: Double) -> Double {
    min(ramp(t, inStart, inEnd), 1 - ramp(t, outStart, outEnd))
}

private let emberCard = LinearGradient(colors: Sky.ember.stops(drain: 0), startPoint: .topLeading, endPoint: .bottomTrailing)

private let duskCard = LinearGradient(colors: Sky.dusk.stops(drain: 0.2), startPoint: .topLeading, endPoint: .bottomTrailing)

private let tealCard = LinearGradient(colors: [Color(red: 0.07, green: 0.23, blue: 0.23), Color(red: 0.18, green: 0.49, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing)

/// The tag row filters the list (Kitchen: the Work timer drops out), then a note
/// appears under the first timer.
private struct TagsScene: View {
    let t: Double

    var body: some View {
        let filtered = ramp(t, 0.2, 0.32)
        let note = ramp(t, 0.5, 0.62)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip(String(localized: "All"), on: filtered < 0.5)
                chip("Kitchen", on: filtered >= 0.5)
                    .overlay {
                        Circle().stroke(.white.opacity(0.8), lineWidth: 2)
                            .frame(width: 18 + 26 * ramp(t, 0.14, 0.26), height: 18 + 26 * ramp(t, 0.14, 0.26))
                            .opacity(pulse(t, 0.12, 0.16, 0.24, 0.3))
                    }
                chip("Work", on: false)
            }
            card("PIZZA", tag: "Kitchen", digits: "13:51", fill: emberCard)
            if note > 0 {
                Text(verbatim: "Turn at half time")
                    .font(.caption2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(width: 230, alignment: .leading)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(note)
            }
            card("REPORT", tag: "Work", digits: "42:10", fill: duskCard)
                .frame(height: 50 * (1 - filtered), alignment: .top)
                .clipped()
                .opacity(1 - filtered)
            card("EGGS", tag: "Kitchen", digits: "06:10", fill: tealCard)
        }
        .frame(width: 240, height: 210, alignment: .top)
    }

    private func chip(_ title: String, on: Bool) -> some View {
        Text(verbatim: title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(on ? Color.white.opacity(0.9) : .white.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? Color.black : .white)
    }

    private func card(_ name: String, tag: String, digits: String, fill: LinearGradient) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(verbatim: name).skyLabel(9).opacity(0.9)
                    Text(verbatim: tag).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.22), in: Capsule())
                }
                Text(verbatim: digits).skyDigits(20, weight: .regular)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 230, height: 50)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A week of day bars growing in, the week's total and the days-in-a-row streak.
private struct StatsScene: View {
    let t: Double
    private let days: [Double] = [0.35, 0.6, 0.2, 0.8, 0.55, 0.9, 0.45]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                tile(value: "6h 40m", label: String(localized: "This week"), shown: ramp(t, 0.45, 0.55))
                tile(value: "4", label: String(localized: "Days in a row"), shown: ramp(t, 0.6, 0.7))
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days.indices, id: \.self) { i in
                    let grow = ramp(t, 0.05 + Double(i) * 0.05, 0.25 + Double(i) * 0.05)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(i == days.count - 1 ? Color(red: 1, green: 0.62, blue: 0.25) : .white.opacity(0.75))
                        .frame(width: 20, height: max(2, 90 * days[i] * grow))
                }
            }
            .frame(height: 92, alignment: .bottom)
        }
        .frame(width: 250, height: 210)
    }

    private func tile(value: String, label: String, shown: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.headline.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).opacity(0.75)
        }
        .padding(10)
        .frame(width: 118, alignment: .leading)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(0.25 + 0.75 * shown)
    }
}

/// Settings' "Test my alarm": tapped, a five-second count, the alarm rings, "Did it ring?"
private struct TestAlarmScene: View {
    let t: Double

    var body: some View {
        let counting = t >= 0.15 && t < 0.55
        let left = max(1, Int((5 * (1 - ramp(t, 0.15, 0.55))).rounded(.up)))
        let ringing = t >= 0.55 && t < 0.78
        let asked = ramp(t, 0.78, 0.86)
        VStack(spacing: 16) {
            Text("Test my alarm")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    Capsule().stroke(.white.opacity(0.8), lineWidth: 2)
                        .scaleEffect(1 + 0.25 * ramp(t, 0.06, 0.16))
                        .opacity(pulse(t, 0.04, 0.08, 0.13, 0.17))
                }
            ZStack {
                if counting {
                    Text(verbatim: "\(left)").skyDigits(54, weight: .thin)
                }
                if ringing {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                        .rotationEffect(.degrees(sin(t * 120) * 10))
                }
                if asked > 0 {
                    VStack(spacing: 10) {
                        Text("Did it ring?").font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            Label("Yes", systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.white.opacity(0.22), in: Capsule())
                        }
                    }
                    .opacity(asked)
                }
            }
            .frame(height: 90)
        }
        .frame(width: 250, height: 210)
    }
}

/// Messages: a countdown set to repeat weekly, a saved sequence started, then a removed
/// timer brought back with Undo.
private struct MessagesParityScene: View {
    let t: Double

    var body: some View {
        VStack(spacing: 10) {
            row(title: String(localized: "Repeat"), value: "Weekly", shown: ramp(t, 0.05, 0.15))
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(emberCard).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Pomodoro").font(.footnote.weight(.semibold))
                    Text(verbatim: "25 + 5 min").font(.caption2).opacity(0.7)
                }
                Spacer()
                Text("Start").font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 230)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(0.2 + 0.8 * ramp(t, 0.3, 0.4))
            HStack {
                Text("Removed “\("Tea")”").font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("Undo").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.22), in: Capsule())
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(width: 230)
            .glassEffect(.regular, in: Capsule())
            .offset(y: 20 * (1 - ramp(t, 0.55, 0.65)))
            .opacity(pulse(t, 0.55, 0.65, 0.95, 1))
        }
        .frame(width: 250, height: 210)
    }

    private func row(title: String, value: String, shown: Double) -> some View {
        HStack {
            Text(title).font(.footnote)
            Spacer()
            Text(verbatim: value).font(.footnote.weight(.semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 230)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(0.2 + 0.8 * shown)
    }
}
