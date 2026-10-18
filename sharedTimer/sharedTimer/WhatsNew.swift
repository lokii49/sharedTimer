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
    static let contentVersion = "1.0.5"
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
        Feature(id: 0, title: String(localized: "Links that say what they are"),
                body: String(localized: "Shared links now open from mirrornotes.org, and Messages shows the timer's name before anyone taps.")),
        Feature(id: 1, title: String(localized: "Live or snapshot, at a glance"),
                body: String(localized: "The share screen shows the timer and tells you whether the link stays in sync.")),
        Feature(id: 2, title: String(localized: "Share across the room"),
                body: String(localized: "Show a QR code. Anyone who scans it can watch the countdown but can't change it.")),
        Feature(id: 3, title: String(localized: "You decide who has it"),
                body: String(localized: "See who has a shared timer, remove someone, or stop sharing.")),
        Feature(id: 4, title: String(localized: "Keep a sequence you were sent"),
                body: String(localized: "Save a friend's Pomodoro or fasting plan as your own template.")),
        Feature(id: 5, title: String(localized: "Make it yours"),
                body: String(localized: "Set the name people see, pick one of four alarm tones, and replay this tour, all in Settings.")),
        Feature(id: 6, title: String(localized: "Timer speaks your language"),
                body: String(localized: "Ten languages, clearer VoiceOver and larger text. Share works again from a timer's own screen, too."))
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

    private var period: Double { [5, 4, 3.2, 6, 5, 6, 10][index] }
    private var restingT: Double { [0.6, 0.5, 0.5, 0.3, 0.6, 0.6, 0.45][index] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? restingT : (seconds.truncatingRemainder(dividingBy: period)) / period
            Group {
                switch index {
                case 0: LinkPreviewScene(t: t)
                case 1: LiveSnapshotScene(t: t)
                case 2: QRScene(t: t)
                case 3: ManageSharingScene(t: t)
                case 4: TemplateScene(t: t)
                case 5: SettingsScene()
                default: LanguagesScene(t: t)
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

/// A Messages link bubble sliding in, carrying the timer's name and what it is.
private struct LinkPreviewScene: View {
    let t: Double

    var body: some View {
        let shown = pulse(t, 0.05, 0.3, 0.88, 1.0)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Pasta").font(.subheadline.weight(.semibold))
                Text("8 min timer").font(.caption).opacity(0.85)
            }
            .padding(12)
            .frame(width: 176, alignment: .leading)
            .background(emberCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(verbatim: "mirrornotes.org").font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.3)))
        .opacity(shown)
        .offset(x: -30 * (1 - ramp(t, 0.05, 0.3)))
    }
}

/// The timer card with the two link kinds; "Live" breathes.
private struct LiveSnapshotScene: View {
    let t: Double

    var body: some View {
        let breathe = 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 2 * .pi))
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Pasta").skyLabel(11).opacity(0.85)
                Text(verbatim: "07:42").skyDigits(34, weight: .thin)
            }
            .padding(14)
            .frame(width: 200, alignment: .leading)
            .background(emberCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.24, green: 0.71, blue: 0.47)).frame(width: 9, height: 9).opacity(breathe)
                    Text("Live")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(red: 0.23, green: 0.08, blue: 0.19))
                .frame(width: 96, height: 34)
                .background(.white.opacity(0.92), in: Capsule())
                Text("Snapshot")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 96, height: 34)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            }
        }
    }
}

/// A real QR code (the same generator as the share sheet) with a scan line, view-only.
private struct QRScene: View {
    let t: Double
    private static let code = QRCode.image(for: URL(string: "https://mirrornotes.org/timer?label=Pasta")!)

    var body: some View {
        let scan = 0.5 - 0.5 * cos(t * 2 * .pi)
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                if let code = Self.code {
                    Image(uiImage: code).interpolation(.none).resizable().frame(width: 128, height: 128)
                }
                Capsule().fill(Color(red: 1, green: 0.6, blue: 0.32)).frame(width: 140, height: 3)
                    .offset(y: 128 * scan)
            }
            .padding(8)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Label("View only", systemImage: "eye")
                .font(.footnote.weight(.semibold))
        }
    }
}

/// The shared timer at the centre of the people who have it; one is removed mid-loop.
private struct ManageSharingScene: View {
    let t: Double

    var body: some View {
        // "M" fades out (removed) mid-loop and returns just before the loop restarts.
        let removed = ramp(t, 0.45, 0.6) - ramp(t, 0.92, 1.0)
        let people: [(String, CGFloat, CGFloat)] = [("S", 0, -70), ("A", 80, 0), ("M", 0, 70), ("R", -80, 0)]
        ZStack {
            ForEach(people.indices, id: \.self) { i in
                let p = people[i]
                let fade = p.0 == "M" ? 1 - removed : 1
                Path { path in
                    path.move(to: CGPoint(x: 130, y: 105))
                    path.addLine(to: CGPoint(x: 130 + p.1, y: 105 + p.2))
                }
                .stroke(.white.opacity(0.35), lineWidth: 1.5)
                .opacity(fade)
                Text(verbatim: p.0)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.2), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.5)))
                    .position(x: 130 + p.1, y: 105 + p.2)
                    .opacity(fade)
            }
            Text(verbatim: "Pasta")
                .font(.footnote.weight(.semibold))
                .frame(width: 62, height: 62)
                .background(emberCard, in: Circle())
                .position(x: 130, y: 105)
        }
    }
}

/// A received Work/Rest sequence drops into a bookmark.
private struct TemplateScene: View {
    let t: Double

    var body: some View {
        let drop = pulse(t, 0.05, 0.35, 0.88, 1.0)
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("Work").skyLabel(10)
                    .frame(width: 110, height: 34)
                    .background(emberCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Rest").skyLabel(10)
                    .frame(width: 62, height: 34)
                    .background(.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .opacity(drop)
            .offset(y: -36 * (1 - ramp(t, 0.05, 0.35)))
            Image(systemName: ramp(t, 0.35, 0.4) > 0 && t < 0.9 ? "bookmark.fill" : "bookmark")
                .font(.system(size: 64, weight: .light))
        }
    }
}

/// Settings in miniature: the name card's preview sentence and the tone chips.
private struct SettingsScene: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name").skyLabel(9).opacity(0.8)
                Text(verbatim: "Sam").font(.system(size: 28, weight: .thin))
            }
            .padding(12)
            .frame(width: 236, alignment: .leading)
            .background(LinearGradient(colors: Sky.dusk.stops(drain: 0), startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("\("Sam") paused Pasta · 4:12 left")
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.18), in: Capsule())
            HStack(spacing: 5) {
                ForEach(AlarmTone.allCases) { tone in
                    Text(tone.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 55, height: 28)
                        .foregroundStyle(tone == .ember ? Color(red: 0.23, green: 0.08, blue: 0.19) : .white)
                        .background(.white.opacity(tone == .ember ? 0.92 : 0.14), in: Capsule())
                }
            }
        }
    }
}

/// Ten scripts take turns in the middle of a ring of ten points.
private struct LanguagesScene: View {
    let t: Double
    private static let names = ["Timer", "计时器", "टाइमर", "Temporizador", "مؤقت", "Minuteur", "টাইমার", "Timer", "Таймер", "Pengatur waktu"]

    var body: some View {
        let slot = t * Double(Self.names.count)
        let index = min(Self.names.count - 1, Int(slot))
        let local = slot - Double(index)
        VStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
                    .frame(width: 140, height: 140)
                ForEach(0..<Self.names.count, id: \.self) { i in
                    let angle = Double(i) / Double(Self.names.count) * 2 * .pi - .pi / 2
                    Circle().fill(.white.opacity(i == index ? 1 : 0.55))
                        .frame(width: i == index ? 10 : 7, height: i == index ? 10 : 7)
                        .offset(x: cos(angle) * 70, y: sin(angle) * 70)
                }
                Text(verbatim: Self.names[index])
                    .font(.system(size: 22, weight: .light))
                    .opacity(min(ramp(local, 0, 0.15), 1 - ramp(local, 0.85, 1)))
            }
            .frame(height: 150)
            Text("VoiceOver · larger text").skyLabel(9).opacity(0.75)
        }
    }
}
