//
//  Sky.swift
//  sharedTimer
//
//  "Horizon" — time as light. Every timer renders as a living gradient sky that drains
//  toward sunrise as the clock runs: a short timer burns like an ember, an hours-long one
//  sits at dusk, a far-off countdown rests in deep night and brightens as the day nears.
//  Paused timers hold in a green mist; finished ones go overcast. The sky IS the state —
//  you feel how much time is left before you read it.
//
//  Duplicated verbatim into each target that needs it, the same way TimerModel.swift is —
//  see CLAUDE.md. The app chrome is dark-first (skies need a dark room); text placed ON a
//  sky is always white — the fresh ends of every family are deep enough to carry it.
//

import SwiftUI

enum Sky {

    // MARK: Families

    /// One gradient stop, in plain RGB so stops can be lerped.
    struct Stop {
        let r: Double, g: Double, b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        func mixed(toward other: Stop, by t: Double) -> Stop {
            let k = min(1, max(0, t))
            return Stop(r: r + (other.r - r) * k,
                        g: g + (other.g - g) * k,
                        b: b + (other.b - b) * k)
        }
    }

    /// A family is a fresh sky (full time remaining) and the sunrise it drains toward.
    struct Family {
        let fresh: [Stop]
        let drained: [Stop]

        func stops(drain: Double) -> [Color] {
            // Ease the drain so most of the shift happens in the back half — the sky
            // holds its mood for a while, then visibly turns as the end approaches.
            let eased = drain * drain
            return zip(fresh, drained).map { $0.mixed(toward: $1, by: eased).color }
        }
    }

    /// Under an hour: ember — violet dusk burning down to hot orange.
    static let ember = Family(
        fresh: [Stop(r: 0.20, g: 0.07, b: 0.35), Stop(r: 0.65, g: 0.19, b: 0.34), Stop(r: 1.00, g: 0.60, b: 0.32)],
        drained: [Stop(r: 0.48, g: 0.18, b: 0.39), Stop(r: 0.88, g: 0.42, b: 0.34), Stop(r: 1.00, g: 0.82, b: 0.54)]
    )

    /// Under a day: dusk — deep blue lifting toward a pale warm horizon.
    static let dusk = Family(
        fresh: [Stop(r: 0.05, g: 0.12, b: 0.31), Stop(r: 0.20, g: 0.33, b: 0.61), Stop(r: 0.42, g: 0.62, b: 0.80)],
        drained: [Stop(r: 0.24, g: 0.43, b: 0.66), Stop(r: 0.50, g: 0.65, b: 0.85), Stop(r: 1.00, g: 0.85, b: 0.66)]
    )

    /// Days and beyond: night — near-black indigo that only begins to dawn late.
    static let night = Family(
        fresh: [Stop(r: 0.03, g: 0.05, b: 0.18), Stop(r: 0.11, g: 0.18, b: 0.43), Stop(r: 0.25, g: 0.33, b: 0.61)],
        drained: [Stop(r: 0.11, g: 0.18, b: 0.43), Stop(r: 0.29, g: 0.40, b: 0.72), Stop(r: 0.94, g: 0.66, b: 0.41)]
    )

    /// Paused: mist — held, green, going nowhere. The light end stays deep enough to
    /// carry white text.
    static let mist = [
        Stop(r: 0.07, g: 0.18, b: 0.17).color,
        Stop(r: 0.16, g: 0.38, b: 0.34).color,
        Stop(r: 0.38, g: 0.64, b: 0.55).color
    ]

    /// Finished: overcast — the color has left the sky.
    static let overcast = [
        Stop(r: 0.13, g: 0.13, b: 0.15).color,
        Stop(r: 0.22, g: 0.22, b: 0.26).color,
        Stop(r: 0.35, g: 0.35, b: 0.40).color
    ]

    // MARK: The one entry point

    static func colors(for payload: TimerPayload, at date: Date = Date()) -> [Color] {
        if payload.isExpired {
            return overcast
        }
        if payload.isPaused {
            return mist
        }
        let family: Family = payload.duration < 3600 ? ember : (payload.duration < 86400 ? dusk : night)
        return family.stops(drain: 1 - payload.progress(at: date))
    }

    static func gradient(for payload: TimerPayload, at date: Date = Date()) -> LinearGradient {
        LinearGradient(colors: colors(for: payload, at: date), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Day-aware "when" for the pending state: "Today 3:00 PM" / "Tomorrow 7:00 AM" /
    /// "Sun 3:00 PM" within a week / "27 Sep, 3:00 PM" beyond that. Deliberately not a
    /// relative "in 3 days" -- that's the ticking-countdown framing the pending state
    /// was built to avoid (see CLAUDE.md). Non-private (unlike most of this file's
    /// per-view helpers) so TimerDetailView can share it instead of re-deriving its own.
    static func pendingStartText(for start: Date, at now: Date) -> String {
        let calendar = Calendar.current
        let time = start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(start, inSameDayAs: now) {
            return "Today \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if let sixDaysOut = calendar.date(byAdding: .day, value: 6, to: now), start < sixDaysOut {
            return "\(start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(start.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    /// "2 phases · 7 loops" -- the pending-state caption for a sequence not yet
    /// started. `TimerPayload.sequenceCaption`'s "Phase 1 of 2 · Loop 1 of 7" reads as
    /// already running, so this is a separate function rather than a change to it.
    static func pendingSequenceCaption(_ sequence: SequenceInfo) -> String {
        "\(sequence.phases.count) phase\(sequence.phases.count == 1 ? "" : "s") · \(sequence.loopCount) loop\(sequence.loopCount == 1 ? "" : "s")"
    }

    /// "FAST · 0D 16H" -- what phase 0 actually is, for the secondary slot next to the
    /// big start date/time. Picked over "ends ..." (start + every phase*loop) for
    /// space: the digit/secondary HStack has to fit "Tomorrow 10:21 PM" and this next
    /// to it, and this is the shorter of the two candidates.
    static func pendingFirstPhaseText(_ sequence: SequenceInfo) -> String? {
        guard let first = sequence.phases.first else { return nil }
        return "\(first.label) · \(TimeFormat.daysHours(first.duration))"
    }

    /// Live Activity variant: the activity state carries no original duration, so the
    /// family is picked from what REMAINS and shown fresh (no drain) — close enough for a
    /// glance surface, and it never lies about scale.
    static func colors(endDate: Date, pausedRemaining: TimeInterval?, at date: Date = Date()) -> [Color] {
        if pausedRemaining != nil {
            return mist
        }
        let remaining = endDate.timeIntervalSince(date)
        if remaining <= 0 {
            return overcast
        }
        let family: Family = remaining < 3600 ? ember : (remaining < 86400 ? dusk : night)
        return family.stops(drain: 0)
    }

    static func gradient(endDate: Date, pausedRemaining: TimeInterval?, at date: Date = Date()) -> LinearGradient {
        LinearGradient(colors: colors(endDate: endDate, pausedRemaining: pausedRemaining, at: date),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Chrome

    /// The dark room the skies hang in — the app's fixed background.
    static let room = Color(red: 0.039, green: 0.039, blue: 0.055) // #0A0A0E

    /// Secondary text on the room.
    static let roomInk = Color.white.opacity(0.55)
}

// MARK: - Type voice

extension Text {
    /// Small-caps label voice used on skies and chrome: uppercase, tracked, semibold.
    func skyLabel(_ size: CGFloat = 11) -> some View {
        self.font(.system(size: size, weight: .semibold))
            .tracking(size * 0.16)
            .textCase(.uppercase)
    }

    /// The thin digits that glow against a sky.
    func skyDigits(_ size: CGFloat, weight: Font.Weight = .thin) -> Text {
        self.font(.system(size: size, weight: weight))
            .monospacedDigit()
    }
}

// MARK: - Glass pill button

/// Frosted capsule for controls that sit on a sky — translucent, never opaque chrome.
struct GlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.17), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassPillButtonStyle {
    static var glassPill: GlassPillButtonStyle { GlassPillButtonStyle() }
}

// MARK: - Sky card

/// The signature list row: one sky per timer. Label in small caps at the top, thin digits
/// glowing at the bottom edge, the end time opposite. The gradient itself carries the
/// state — ember/dusk/night by scale, mist when held, overcast when done.
struct SkyCard: View {
    let payload: TimerPayload
    let date: Date

    var body: some View {
        let remaining = payload.remaining
        let pending = payload.isPending(at: date)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(payload.label)
                    .skyLabel(12)
                    .lineLimit(1)
                Spacer()
                if pending {
                    Text("Scheduled").skyLabel(12)
                } else if payload.isPaused {
                    Text("Paused").skyLabel(12)
                } else if payload.isExpired {
                    Text("Time's up").skyLabel(12)
                }
            }
            .foregroundStyle(.white.opacity(0.85))

            // "Phase 1 of 2 · Loop 1 of 7" would misread as already running while
            // pending -- a plain phase/loop count instead.
            if pending, let sequence = payload.sequence {
                Text(Sky.pendingSequenceCaption(sequence))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            } else if let caption = payload.sequenceCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline) {
                Text(pendingDigits ?? TimeFormat.display(remaining > 0 ? remaining : payload.duration))
                    .skyDigits(34, weight: .regular)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                // Same small-caps voice as the label — every word on a sky speaks it.
                Text(endText)
                    .skyLabel(12)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(14)
        .frame(height: 104)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Sky.gradient(for: payload, at: date))
                // Reads as "not live yet" at a glance, not just via the "Scheduled"
                // label -- same sky family, visibly muted.
                .saturation(pending ? 0.35 : 1)
                .brightness(pending ? -0.1 : 0)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The start date/time itself, day-aware, not a ticking countdown to it -- a live
    /// countdown in the big digit slot read as urgent/already-running, which is what
    /// the "Scheduled" state exists to avoid. Once the start passes, `isPending` goes
    /// false on its own and this stops applying.
    private var pendingDigits: String? {
        guard let start = payload.scheduledStartDate, payload.isPending(at: date) else { return nil }
        return Sky.pendingStartText(for: start, at: date)
    }

    private var endText: String {
        // What phase 0 actually is, not the start time again (the big digits already
        // show that) -- e.g. "Fast · 0d 16h".
        if payload.isPending(at: date), let sequence = payload.sequence, let phaseText = Sky.pendingFirstPhaseText(sequence) {
            return phaseText
        }
        if payload.isPaused {
            return "held"
        }
        if payload.isExpired {
            return "finished \(payload.endDate.formatted(date: .omitted, time: .shortened))"
        }
        if payload.kind == .countdown {
            return TimeFormat.targetDate(payload.endDate)
        }
        return "ends \(payload.endDate.formatted(date: .omitted, time: .shortened))"
    }
}
