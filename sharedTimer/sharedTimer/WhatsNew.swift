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
    static let contentVersion = "1.0.7"
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
                              isExistingInstall: TimerStore.hasStoredData)
        defaults.set(current, forKey: seenVersionKey)
        return show
    }

    struct Feature: Identifiable {
        let id: Int
        let title: String
        let body: String
    }

    static let features: [Feature] = [
        Feature(id: 0, title: String(localized: "Made for iPad"),
                body: String(localized: "Your timers in a sidebar, the live sky right beside them.")),
        Feature(id: 1, title: String(localized: "Countdowns that come back"),
                body: String(localized: "Repeat a countdown every day, week or month. Next Week skips ahead when you need it.")),
        Feature(id: 2, title: String(localized: "Everything you've timed"),
                body: String(localized: "Finished timers stay in History for 90 days. Run one again in a tap.")),
        Feature(id: 3, title: String(localized: "Know before it ends"),
                body: String(localized: "Get a heads-up halfway or a few minutes before the end, and see “+2:13” once it's over.")),
        Feature(id: 4, title: String(localized: "On every screen you use"),
                body: String(localized: "Sync your own timers with iCloud, and run one together in a FaceTime call with SharePlay.")),
        Feature(id: 5, title: String(localized: "Just ask"),
                body: String(localized: "Ask Siri how long is left, then pause or add a minute from the answer. Describe a sequence in your own words with Apple Intelligence.")),
        Feature(id: 6, title: String(localized: "Easier on the eyes"),
                body: String(localized: "Clearer text on every sky, Liquid Glass buttons, bigger cards with large text, and a sun to keep the screen on."))
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

    private var period: Double { [5, 6, 5, 6, 5, 5, 5][index] }
    private var restingT: Double { [0.5, 0.45, 0.6, 0.75, 0.5, 0.6, 0.5][index] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? restingT : (seconds.truncatingRemainder(dividingBy: period)) / period
            Group {
                switch index {
                case 0: IPadScene(t: t)
                case 1: RepeatScene(t: t)
                case 2: HistoryScene(t: t)
                case 3: OvertimeScene(t: t)
                case 4: DevicesScene(t: t)
                case 5: SiriScene(t: t)
                default: ReadableScene(t: t)
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
private let nightCard = LinearGradient(colors: Sky.night.stops(drain: 0.2), startPoint: .topLeading, endPoint: .bottomTrailing)

/// An iPad in miniature: a sidebar of small skies, the selected one filling the right.
private struct IPadScene: View {
    let t: Double

    var body: some View {
        let selected = Int(t * 3) % 3
        let skies = [emberCard, duskCard, nightCard]
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(skies[i])
                        .frame(width: 64, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(i == selected ? 0.9 : 0), lineWidth: 1.5))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(width: 80, height: 168)
            .background(.black.opacity(0.35))
            ZStack {
                skies[selected]
                Text(verbatim: ["07:42", "3:12:05", "12d"][selected]).skyDigits(30, weight: .thin)
            }
            .frame(width: 150, height: 168)
            .animation(.easeInOut(duration: 0.35), value: selected)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 2))
    }
}

/// The Repeat choices, the highlight moving Daily → Weekly → Monthly.
private struct RepeatScene: View {
    let t: Double

    var body: some View {
        let chosen = Int(t * 3) % 3
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Standup").skyLabel(10).opacity(0.85)
                Text(["Every day", "Every Monday", "Every month on the 1st"][chosen]).font(.footnote)
            }
            .padding(12)
            .frame(width: 220, alignment: .leading)
            .background(nightCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Text(["Daily", "Weekly", "Monthly"][i])
                        .font(.caption.weight(.semibold))
                        .frame(width: 70, height: 30)
                        .foregroundStyle(i == chosen ? Color(red: 0.05, green: 0.12, blue: 0.31) : .white)
                        .background(.white.opacity(i == chosen ? 0.92 : 0.14), in: Capsule())
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: chosen)
    }
}

/// Two finished runs settle into History; Run again glows.
private struct HistoryScene: View {
    let t: Double

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { i in
                let shown = pulse(t, 0.0 + Double(i) * 0.08, 0.15 + Double(i) * 0.08, 0.96, 1.0)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: ["Pasta", "Bread proof"][i]).font(.footnote.weight(.semibold))
                        Text(verbatim: ["8m", "45m"][i]).font(.caption2).opacity(0.85)
                    }
                    Spacer()
                    Text("Run again")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(i == 0 ? 0.2 + 0.25 * ramp(t, 0.5, 0.65) : 0.2), in: Capsule())
                }
                .padding(10)
                .frame(width: 230)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: Sky.ember.stops(drain: 1), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .saturation(0.55).brightness(-0.12)
                }
                .opacity(shown)
                .offset(y: 16 * (1 - ramp(t, 0.0 + Double(i) * 0.08, 0.15 + Double(i) * 0.08)))
            }
        }
    }
}

/// A heads-up chip, the timer running out, then the overtime count in ember orange.
private struct OvertimeScene: View {
    let t: Double

    var body: some View {
        let left = max(0, 6 - t * 10)                // 6 s left → 0 at t = 0.6
        let over = max(0, (t - 0.6) * 10)
        VStack(spacing: 12) {
            Label("5 min left", systemImage: "bell")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.18), in: Capsule())
                .opacity(pulse(t, 0.0, 0.1, 0.45, 0.55))
            Text(verbatim: over > 0 ? "+" + TimeFormat.display(over) : TimeFormat.display(left))
                .skyDigits(40, weight: .thin)
                .foregroundStyle(over > 0 ? Sky.overtimeInk : .white)
                .frame(width: 200, height: 80)
                .background(over > 0 ? LinearGradient(colors: Sky.overcast, startPoint: .topLeading, endPoint: .bottomTrailing) : emberCard,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// A phone and an iPad on the same timer, joined by iCloud and SharePlay.
private struct DevicesScene: View {
    let t: Double

    var body: some View {
        let dash = t * 18
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(emberCard)
                .frame(width: 54, height: 100)
                .overlay(Text(verbatim: "07:42").font(.caption2.monospacedDigit()))
            VStack(spacing: 6) {
                Image(systemName: "icloud")
                Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 56, y: 0)) }
                    .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5, 4], dashPhase: -dash))
                    .frame(width: 56, height: 2)
                Image(systemName: "shareplay")
            }
            .font(.system(size: 20))
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(emberCard)
                .frame(width: 104, height: 136)
                .overlay(Text(verbatim: "07:42").skyDigits(22, weight: .thin))
        }
    }
}

/// Siri's answer card, with Pause and +1:00 to tap.
private struct SiriScene: View {
    let t: Double

    var body: some View {
        let shown = pulse(t, 0.05, 0.25, 0.9, 1.0)
        VStack(spacing: 10) {
            Text("“How long is left on Pasta?”").font(.caption).italic().opacity(0.85)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Pasta").skyLabel(10).opacity(0.85)
                Text(verbatim: "4:12").skyDigits(30, weight: .thin)
                HStack(spacing: 6) {
                    Text(verbatim: "+1:00").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.2), in: Capsule())
                    Text("Pause").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.2), in: Capsule())
                }
            }
            .padding(12)
            .frame(width: 210, alignment: .leading)
            .background(emberCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(shown)
            .scaleEffect(0.94 + 0.06 * ramp(t, 0.05, 0.25))
        }
    }
}

/// A sky card with its corner scrim, glass pills and the Keep Screen On sun.
private struct ReadableScene: View {
    let t: Double

    var body: some View {
        let glow = 0.5 + 0.5 * sin(t * 2 * .pi)
        VStack(spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text(verbatim: "07:42").skyDigits(30, weight: .thin)
                Spacer()
                Text(verbatim: "ENDS 7:48 PM").skyLabel(9)
            }
            .padding(12)
            .frame(width: 220)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: Sky.ember.stops(drain: 0.8), startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(SkyCornerScrim())
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.4))
                    .opacity(0.6 + 0.4 * glow)
                Text("Pause").font(.caption.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
            }
        }
    }
}
