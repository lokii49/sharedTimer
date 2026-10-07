//
//  WhatsNew.swift
//  sharedTimer
//

import SwiftUI

/// Once-per-update "What's New" tour ("Sunrise Walk"): one full-screen page per
/// feature, the sky draining from night toward sunrise as you page through — the same
/// drain a timer's own sky does. Main app only.
enum WhatsNew {
    /// The version whose features the pages below describe. Bump it (and the pages)
    /// when a later release gets its own tour; a release without one shows nothing.
    static let contentVersion = "1.0.4"
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
        Feature(id: 0, title: "Pause from the Lock Screen",
                body: "Pause, resume or stop right on the Lock Screen and Dynamic Island. New Lock Screen widgets show a live ring."),
        Feature(id: 1, title: "Edit any timer",
                body: "Rename it, change its alarm, or move a countdown to a new date. Shared timers update for everyone."),
        Feature(id: 2, title: "Countdowns that come back every year",
                body: "Birthdays and anniversaries repeat yearly. Import them straight from your Calendar."),
        Feature(id: 3, title: "Share a whole sequence",
                body: "Send a Pomodoro or fasting plan in Messages. Everyone follows the same phases, live."),
        Feature(id: 4, title: "Start your usual timer in one tap",
                body: "Recent timers wait in the New Timer screen, on the app icon and in Control Center."),
        Feature(id: 5, title: "Siri, Spotlight and your Watch",
                body: "Ask Siri how long is left, find a timer in Spotlight, or keep one on your watch face.")
    ]
}

struct WhatsNewView: View {
    let onDone: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var features: [WhatsNew.Feature] { WhatsNew.features }
    private var isLast: Bool { page == features.count - 1 }

    /// Night sky drained a little more on each page — the tour ends at sunrise.
    private func skyColors(_ index: Int) -> [Color] {
        Sky.night.stops(drain: Double(index) / Double(max(1, features.count - 1)))
    }

    var body: some View {
        ZStack {
            ForEach(features) { feature in
                LinearGradient(colors: skyColors(feature.id), startPoint: .top, endPoint: .bottom)
                    .opacity(feature.id == page ? 1 : 0)
            }
            .ignoresSafeArea()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: page)

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
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(feature.body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
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

    private var period: Double { [5, 6, 5, 6, 5, 6][index] }
    private var restingT: Double { [0.6, 0.8, 0.7, 0.6, 0.6, 0.6][index] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? restingT : (seconds.truncatingRemainder(dividingBy: period)) / period
            Group {
                switch index {
                case 0: LockScreenScene(t: t, seconds: seconds)
                case 1: EditScene(t: t, seconds: seconds)
                case 2: YearlyScene(t: t)
                case 3: SequenceScene(t: t)
                case 4: QuickStartScene(t: t)
                default: ReachScene(t: t, seconds: seconds)
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

private struct LockScreenScene: View {
    let t: Double
    let seconds: Double

    var body: some View {
        let paused = t > 0.36 && t < 0.9
        let tap = ramp(t, 0.32, 0.44)
        let remaining = 462 - Int(seconds) % 462
        VStack(spacing: 16) {
            Text("9:41").skyDigits(48, weight: .light)
            ZStack {
                LinearGradient(colors: Sky.ember.stops(drain: 0.2), startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: Sky.mist, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(pulse(t, 0.34, 0.42, 0.88, 0.96))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pasta").skyLabel(10).opacity(0.8)
                        Text(TimeFormat.display(TimeInterval(remaining))).skyDigits(34, weight: .light)
                        Text(paused ? "Paused" : "ends at 9:49").font(.caption2).opacity(0.75)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        controlCircle(paused ? "play.fill" : "pause.fill")
                            .overlay(Circle().stroke(.white, lineWidth: 2)
                                .scaleEffect(0.7 + tap * 0.8)
                                .opacity(tap > 0 && tap < 1 ? 1 - tap : 0))
                        controlCircle("xmark")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(width: 240, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func controlCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.22), in: Circle())
    }
}

private struct EditScene: View {
    let t: Double
    let seconds: Double

    private var typed: String {
        let from = "Pasta", to = "Ramen night"
        if t < 0.15 { return from }
        if t < 0.3 { return String(from.prefix(Int((1 - ramp(t, 0.15, 0.3)) * Double(from.count)))) }
        return String(to.prefix(Int((ramp(t, 0.3, 0.6) * Double(to.count)).rounded(.up))))
    }

    var body: some View {
        let caretOn = Int(seconds * 2) % 2 == 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 1) {
                Text(typed).skyLabel(11)
                Rectangle().frame(width: 1.5, height: 13).opacity(caretOn ? 1 : 0)
                Spacer()
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.22), in: Circle())
            }
            Text("12:30").skyDigits(34, weight: .regular)
            Text("ends at 7:30 PM").font(.caption2).opacity(0.75)
        }
        .padding(14)
        .frame(width: 240)
        .background(LinearGradient(colors: Sky.ember.stops(drain: 0.3), startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct YearlyScene: View {
    let t: Double

    var body: some View {
        let flip = pulse(t, 0.45, 0.55, 0.92, 1.0)
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("MAR")
                    .font(.system(size: 12, weight: .bold)).tracking(1.5)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color(red: 0.9, green: 0.28, blue: 0.3))
                    .foregroundStyle(.white)
                Text("14").font(.system(size: 46, weight: .light)).foregroundStyle(.black)
                ZStack {
                    Text("2026").offset(y: -20 * flip)
                    Text("2027").offset(y: 20 - 20 * flip)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(height: 20)
                .clipped()
                .padding(.bottom, 8)
            }
            .frame(width: 108)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 8)

            Label("Repeats yearly", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.17), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        }
    }
}

private struct SequenceScene: View {
    let t: Double

    var body: some View {
        // Work 25 / Rest 5, twice: each segment fills in turn.
        let segments: [(String, CGFloat, ClosedRange<Double>)] = [
            ("Work", 5, 0...0.3), ("Rest", 2, 0.3...0.42), ("Work", 5, 0.42...0.72), ("Rest", 2, 0.72...0.84)
        ]
        VStack(alignment: .trailing, spacing: 14) {
            GeometryReader { geo in
                let unit = (geo.size.width - 12) / 14
                HStack(spacing: 4) {
                    ForEach(segments.indices, id: \.self) { i in
                        let seg = segments[i]
                        let fill = ramp(t, seg.2.lowerBound, seg.2.upperBound)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.18))
                            RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.45))
                                .frame(width: unit * seg.1 * fill)
                            Text(seg.0).skyLabel(9).padding(.leading, 6)
                        }
                        .frame(width: unit * seg.1)
                    }
                }
            }
            .frame(height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("Pomodoro · Phase 2 of 4").font(.caption)
                Text("Tap to follow along").font(.caption2).opacity(0.75)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(red: 0.18, green: 0.49, blue: 0.96),
                        in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18))
            .opacity(pulse(t, 0.08, 0.16, 0.92, 1.0))
            .offset(y: 12 * (1 - ramp(t, 0.08, 0.16)))
        }
        .frame(width: 240)
    }
}

private struct QuickStartScene: View {
    let t: Double

    var body: some View {
        let press = 1 - 0.07 * pulse(t, 0.3, 0.34, 0.34, 0.4)
        let banner = pulse(t, 0.38, 0.46, 0.86, 0.94)
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: Sky.ember.stops(drain: 0), startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 18)
                Text("Pasta started").font(.caption.weight(.semibold)) + Text(" · 8 min").font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.13).opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(banner)
            .offset(y: -10 * (1 - banner))

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile { Image(systemName: "flashlight.on.fill") }
                    tile { Image(systemName: "moon.fill") }
                }
                GridRow {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 34, height: 34)
                            .background(Color(red: 1, green: 0.6, blue: 0.32), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Start Pasta 8m").font(.caption.weight(.semibold))
                            Text("Timer").font(.caption2).opacity(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 138, height: 64)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(press)
                    .gridCellColumns(2)
                }
            }
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 20))
            .frame(width: 64, height: 64)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ReachScene: View {
    let t: Double
    let seconds: Double

    var body: some View {
        let answer = pulse(t, 0.25, 0.35, 0.92, 1.0)
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.black)
                RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color(white: 0.25), lineWidth: 3)
                Circle().stroke(.white.opacity(0.18), lineWidth: 6).frame(width: 64, height: 64)
                Circle()
                    .trim(from: 0, to: 0.84 - 0.64 * t)
                    .stroke(Color(red: 1, green: 0.6, blue: 0.32), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 64, height: 64)
                Text("6m").font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            .frame(width: 94, height: 110)

            VStack(alignment: .leading, spacing: 8) {
                Circle()
                    .fill(AngularGradient(colors: [.pink, .orange, .cyan, .purple, .pink], center: .center))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 3) * 120))
                Text("“How long is left on Pasta?”").font(.caption).opacity(0.85)
                Text("6 minutes left")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(answer)
                    .offset(y: 6 * (1 - answer))
            }
            .frame(width: 130, alignment: .leading)
        }
    }
}
