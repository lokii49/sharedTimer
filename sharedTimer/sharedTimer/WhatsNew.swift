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
    static let contentVersion = "1.0.9"
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

    static let features: [Feature] = [
        Feature(id: 0, title: String(localized: "Widgets that keep up"),
                body: String(localized: "Finishes and next phases show right on time, a tap opens the timer, and there's a one-line Lock Screen widget and a look for tinted Home Screens.")),
        Feature(id: 1, title: String(localized: "More in Messages"),
                body: String(localized: "An open timer follows every change, a repeating countdown skips ahead with Next Week, and sharing again replaces the old card.")),
        Feature(id: 2, title: String(localized: "Keep the screen on"),
                body: String(localized: "A new lock button keeps the screen awake while you watch, and says so.")),
        Feature(id: 3, title: String(localized: "Alarms that listen"),
                body: String(localized: "Next, Next Week and the other alarm buttons now dismiss the alarm right away, and ✕ on a repeating countdown skips just this one."))
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

    private var period: Double { [6, 6, 5, 6][index] }
    private var restingT: Double { [0.8, 0.75, 0.6, 0.85][index] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let t = reduceMotion ? restingT : (seconds.truncatingRemainder(dividingBy: period)) / period
            Group {
                switch index {
                case 0: WidgetScene(t: t)
                case 1: MessagesScene(t: t)
                case 2: KeepAwakeScene(t: t)
                default: AlarmButtonsScene(t: t)
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

/// A small widget counting its last seconds into "Time's up" with Repeat, on time; the
/// one-line Lock Screen widget above it; a tap opening the timer.
private struct WidgetScene: View {
    let t: Double

    var body: some View {
        let left = max(0, 3 - t * 6)                 // 3 s left → 0 at t = 0.5
        let finished = left <= 0
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "timer")
                Text(verbatim: "Tea  " + TimeFormat.display(finished ? 0 : left.rounded(.up)))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .opacity(0.85)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: "TEA").skyLabel(10).opacity(0.85)
                    Spacer()
                    if finished { Text("Time's up").skyLabel(9).opacity(0.85) }
                }
                Spacer(minLength: 0)
                Text(verbatim: TimeFormat.display(finished ? 0 : left.rounded(.up)))
                    .skyDigits(32, weight: .regular)
                Text("Repeat").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.2), in: Capsule())
                    .opacity(finished ? 1 : 0)
            }
            .padding(12)
            .frame(width: 130, height: 130)
            .background(finished ? LinearGradient(colors: Sky.overcast, startPoint: .topLeading, endPoint: .bottomTrailing) : emberCard,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                // The tap that opens the timer.
                Circle().stroke(.white.opacity(0.8), lineWidth: 2)
                    .frame(width: 22 + 30 * ramp(t, 0.75, 0.95), height: 22 + 30 * ramp(t, 0.75, 0.95))
                    .opacity(pulse(t, 0.72, 0.78, 0.92, 0.98))
            }
        }
    }
}

/// An older card folding into its summary as the new one arrives, then "Next Week".
private struct MessagesScene: View {
    let t: Double

    var body: some View {
        let arrived = ramp(t, 0.15, 0.4)
        VStack(alignment: .trailing, spacing: 8) {
            // The earlier card: collapses to its one-line summary.
            Group {
                if arrived < 1 {
                    card(caption: "6 min timer", height: 70 - 40 * arrived)
                        .opacity(1 - 0.4 * arrived)
                } else {
                    Text(verbatim: "Shared timer: Gym").font(.caption2).opacity(0.7)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            card(caption: "every week, next Sat", height: 70)
                .offset(y: 30 * (1 - arrived))
                .opacity(arrived)
            Text("Next Week").font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                .opacity(ramp(t, 0.5, 0.65))
        }
        .frame(width: 230, alignment: .trailing)
    }

    private func card(caption: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Gym").font(.footnote.weight(.semibold))
            Text(verbatim: caption).font(.caption2).opacity(0.8)
        }
        .padding(10)
        .frame(width: 190, height: height, alignment: .topLeading)
        .background(duskCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipped()
    }
}

/// Keep Screen On: the lock fills warm and confirms "Screen stays on".
private struct KeepAwakeScene: View {
    let t: Double

    var body: some View {
        let on = t > 0.3 && t < 0.9
        VStack(spacing: 18) {
            Text("Screen stays on")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .opacity(pulse(t, 0.3, 0.38, 0.62, 0.7))
            Image(systemName: on ? "lock.slash.fill" : "lock.slash")
                .font(.system(size: 34))
                .foregroundStyle(on ? Color(red: 1, green: 0.82, blue: 0.45) : .white)
                .frame(width: 72, height: 72)
                .background(.white.opacity(0.14), in: Circle())
            Text(verbatim: "07:42").skyDigits(30, weight: .thin).opacity(0.85)
        }
    }
}

/// The full-screen alarm's banner (as on the Lock Screen / over the app): ⏩ is tapped,
/// the alarm slides away, and the next phase is running.
private struct AlarmButtonsScene: View {
    let t: Double

    var body: some View {
        let tapped = t > 0.35
        let gone = ramp(t, 0.42, 0.58)
        ZStack(alignment: .top) {
            // What's underneath: the next phase, already running.
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "REST").skyLabel(10).opacity(0.85)
                Text(verbatim: "Phase 2 of 2").font(.caption2).opacity(0.7)
                Spacer(minLength: 0)
                Text(verbatim: "25:00").skyDigits(30, weight: .thin)
            }
            .padding(12)
            .frame(width: 230, height: 110, alignment: .leading)
            .background(emberCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 70)
            .opacity(0.5 + 0.5 * gone)

            // The alarm banner.
            HStack(spacing: 10) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Timer").font(.caption2).opacity(0.7)
                    Text(verbatim: "Work").font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.25))
                    .frame(width: 40, height: 40)
                    .background(Color(red: 1, green: 0.62, blue: 0.25).opacity(tapped ? 0.55 : 0.28), in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.8), lineWidth: 2)
                            .frame(width: 40 + 26 * ramp(t, 0.3, 0.45), height: 40 + 26 * ramp(t, 0.3, 0.45))
                            .opacity(pulse(t, 0.28, 0.32, 0.4, 0.46))
                    }
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(.horizontal, 14)
            .frame(width: 250, height: 62)
            .background(.black, in: Capsule())
            .offset(y: -60 * gone)
            .opacity(1 - gone)
        }
        .frame(width: 260, height: 200, alignment: .top)
    }
}
