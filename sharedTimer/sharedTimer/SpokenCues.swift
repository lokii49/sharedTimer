//
//  SpokenCues.swift
//  sharedTimer
//
//  N1 spoken cues for sequences (owner's picks 2026-11-27,
//  https://claude.ai/artifact/MYccPStwyVDJ9qHPJakeCm): a voice button beside Keep Screen
//  On on a running sequence; lean cues — the phase name and length at each change,
//  "One minute left. Next: …" a minute before (phases of 5 minutes or more), 3-2-1
//  beeps, "Sequence done." at the end — with other audio dipped while it speaks.
//
//  iOS lets the app speak only while it is open on screen, so this is driven by the
//  detail screen's own 1 s tick and is silent whenever the scene isn't active (a phase's
//  full-screen alarm included); returning to the screen announces the current phase.
//  Main app only, never on the wire or in CloudKit.
//

import AVFoundation
import Foundation
import SwiftUI

enum SpokenCue: Equatable {
    case phaseStart(label: String, length: TimeInterval)
    case nextSoon(label: String)
    case beep
    case done

    /// What the voice says (nil for a beep). Localized; the length is spelled out by
    /// the system's duration formatter ("25 minutes").
    var text: String? {
        switch self {
        case .phaseStart(let label, let length):
            let spoken = Duration.seconds(max(1, length.rounded()))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
            return String(localized: "\(label). \(spoken).")
        case .nextSoon(let label): return String(localized: "One minute left. Next: \(label).")
        case .beep: return nil
        case .done: return String(localized: "Sequence done.")
        }
    }
}

enum SpokenCuePlan {
    /// "Now" when the voice is turned on or the screen opens on a running sequence.
    static func announcement(for payload: TimerPayload, at date: Date) -> SpokenCue? {
        let current = payload.advancedSequence(at: date)
        guard let sequence = current.sequence, sequence.loopIndex < sequence.loopCount,
              !current.isPaused, !current.isPending(at: date) else { return nil }
        return .phaseStart(label: current.label, length: max(0, current.endDate.timeIntervalSince(date)))
    }

    /// The cues whose moment falls in `(from, to]`. `from` is clamped to 2 s before `to`,
    /// so reopening the screen after a while doesn't replay a backlog. Pure: the detail
    /// screen calls it from its tick with the previous tick's date.
    static func cues(for payload: TimerPayload, from: Date, to: Date) -> [SpokenCue] {
        let from = max(from, to.addingTimeInterval(-2))
        guard to > from else { return [] }
        let current = payload.advancedSequence(at: from)
        guard current.sequence != nil, !current.isPaused, !current.isPending(at: from) else { return [] }
        let upcoming = current.upcomingSequencePhases(limit: 2)
        guard let now = upcoming.first else { return [] }
        let end = now.endDate
        let next = upcoming.dropFirst().first
        var moments: [(Date, SpokenCue)] = []
        if let next, now.phase.duration >= 300 {
            moments.append((end.addingTimeInterval(-60), .nextSoon(label: next.phase.label)))
        }
        for second in [3.0, 2.0, 1.0] where now.phase.duration > second {
            moments.append((end.addingTimeInterval(-second), .beep))
        }
        if let next {
            moments.append((end, .phaseStart(label: next.phase.label, length: next.phase.duration)))
        } else {
            moments.append((end, .done))
        }
        return moments.filter { $0.0 > from && $0.0 <= to }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// Voice on/off, remembered per sequence pattern (phases and loops), so starting the
/// same saved sequence again talks again. On this phone only.
enum SpokenCuePreference {
    private static let key = "spokenCues.on"

    static func isOn(for payload: TimerPayload, defaults: UserDefaults = .standard) -> Bool {
        guard let signature = signature(payload) else { return false }
        return (defaults.stringArray(forKey: key) ?? []).contains(signature)
    }

    /// By pattern only: turning the voice off on one run turns it off for every run of
    /// the same phases and loops (storing run ids too left an older run still talking).
    static func set(_ on: Bool, for payload: TimerPayload, defaults: UserDefaults = .standard) {
        guard let signature = signature(payload) else { return }
        var set = Set(defaults.stringArray(forKey: key) ?? [])
        if on { set.insert(signature) } else { set.remove(signature) }
        defaults.set(Array(Array(set).sorted().suffix(200)), forKey: key)
    }

    /// The pattern, not the run: phase names and lengths, and the loop count.
    static func signature(_ payload: TimerPayload) -> String? {
        guard let sequence = payload.sequence else { return nil }
        let phases = sequence.phases.map { "\($0.label)|\(Int($0.duration.rounded()))" }.joined(separator: ";")
        return "seq:\(sequence.loopCount)x[\(phases)]"
    }
}

/// Speaks cues with other audio dipped (`.duckOthers`), on the same background queue
/// as the alarm sound (session changes can block). Beeps are a generated tone through
/// the same `.playback` session, so — like the voice — they're heard with the ringer
/// switch on silent.
@MainActor
final class SpokenCuePlayer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpokenCuePlayer()

    private let synthesizer = AVSpeechSynthesizer()
    private var beepPlayer: AVAudioPlayer?
    private var deactivate: DispatchWorkItem?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(_ cue: SpokenCue) {
        // The in-app alarm loop owns the session while it rings.
        guard !AlarmPlayer.shared.isPlaying else { return }
        activate { [self] in
            if let text = cue.text {
                let utterance = AVSpeechUtterance(string: text)
                // App language codes ("zh-Hans", "pt-BR") resolve to a voice of that
                // language — checked on simulator and iPhone (test below pins it).
                utterance.voice = AVSpeechSynthesisVoice(language: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
                synthesizer.speak(utterance)
            } else {
                beep()
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        beepPlayer?.stop()
        scheduleDeactivation(after: 0)
    }

    private func activate(_ then: @escaping @MainActor () -> Void) {
        deactivate?.cancel()
        AlarmPlayer.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    private func beep() {
        if beepPlayer == nil { beepPlayer = try? AVAudioPlayer(data: Self.tone) }
        beepPlayer?.currentTime = 0
        beepPlayer?.play()
        scheduleDeactivation(after: 0.6)
    }

    /// Hand the audio back (music comes back up) shortly after the last cue.
    private func scheduleDeactivation(after seconds: TimeInterval) {
        deactivate?.cancel()
        let work = DispatchWorkItem {
            guard !AlarmPlayer.shared.isPlaying else { return }
            AlarmPlayer.sessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        deactivate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synthesizer.isSpeaking { self.scheduleDeactivation(after: 0.3) }
        }
    }

    /// 0.12 s of 880 Hz, 16-bit mono WAV with a short fade, built once.
    private static let tone: Data = {
        let rate = 44_100, count = Int(Double(rate) * 0.12)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let fade = min(1, Double(min(i, count - i)) / 400)
            samples[i] = Int16(sin(2 * .pi * 880 * Double(i) / Double(rate)) * 0.5 * fade * Double(Int16.max))
        }
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let bytes = count * 2
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + bytes).littleEndian)
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16).littleEndian); put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian); put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: "data".utf8); put(UInt32(bytes).littleEndian)
        samples.forEach { put($0.littleEndian) }
        return data
    }()
}

/// The speaker button beside Keep Screen On on a running sequence.

struct VoiceCueButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(isOn ? KeepAwake.warm : Color.white)
        }
        .accessibilityLabel("Spoken cues")
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityIdentifier("voiceCueButton")
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
