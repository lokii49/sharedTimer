//
//  SpokenCueTests.swift
//  sharedTimerTests
//
//  N1 spoken cues: what is said when (SpokenCuePlan) and what is remembered.
//

import Foundation
import Testing
@testable import sharedTimer

struct SpokenCueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Work 10 min / Rest 5 min, 2 loops, phase 0 ending at `end`.
    private func workout(end: Date, loops: Int = 2) -> TimerPayload {
        var payload = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 600), SequencePhase(label: "Rest", duration: 300)], loopCount: loops)
        payload.endDate = end
        return payload
    }

    @Test func aMinuteBeforeTheChangeItNamesWhatsNext() {
        let end = now.addingTimeInterval(120)
        let cues = SpokenCuePlan.cues(for: workout(end: end), from: end.addingTimeInterval(-61), to: end.addingTimeInterval(-59))
        #expect(cues == [.nextSoon(label: "Rest")])
    }

    @Test func beepsThenTheNewPhaseAtTheBoundary() {
        let end = now.addingTimeInterval(30)
        let payload = workout(end: end)
        #expect(SpokenCuePlan.cues(for: payload, from: end.addingTimeInterval(-3.2), to: end.addingTimeInterval(-1.2)) == [.beep, .beep])
        #expect(SpokenCuePlan.cues(for: payload, from: end.addingTimeInterval(-1.5), to: end.addingTimeInterval(0.5))
                == [.beep, .phaseStart(label: "Rest", length: 300)])
    }

    @Test func theLastPhaseEndsWithDone() {
        // On the last occurrence (loop 2, Rest).
        var payload = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 600), SequencePhase(label: "Rest", duration: 300)], loopCount: 1)
        payload = payload.materializingPhase(globalIndex: 1, startingAt: now)
        let end = payload.endDate
        #expect(SpokenCuePlan.cues(for: payload, from: end.addingTimeInterval(-0.5), to: end.addingTimeInterval(0.5)) == [.done])
    }

    @Test func reopeningDoesNotReplayABacklog() {
        let end = now.addingTimeInterval(30)
        // A tick after a long gap only looks back 2 s.
        #expect(SpokenCuePlan.cues(for: workout(end: end), from: now.addingTimeInterval(-3_600), to: now).isEmpty)
    }

    @Test func shortPhasesSkipTheOneMinuteWarning() {
        var payload = TimerPayload.composeSequence(phases: [SequencePhase(label: "Sprint", duration: 120), SequencePhase(label: "Walk", duration: 60)], loopCount: 3)
        let end = now.addingTimeInterval(90)
        payload.endDate = end
        #expect(SpokenCuePlan.cues(for: payload, from: end.addingTimeInterval(-61), to: end.addingTimeInterval(-59)).isEmpty)
    }

    @Test func pausedOrScheduledSequencesStayQuiet() {
        let end = now.addingTimeInterval(30)
        let paused = workout(end: end).paused(at: now)
        #expect(SpokenCuePlan.cues(for: paused, from: end.addingTimeInterval(-1.5), to: end.addingTimeInterval(0.5)).isEmpty)
        #expect(SpokenCuePlan.announcement(for: paused, at: now) == nil)
        let pending = TimerPayload.composeSequence(phases: [SequencePhase(label: "Work", duration: 600)], loopCount: 1, startDate: Date().addingTimeInterval(3_600))
        #expect(SpokenCuePlan.announcement(for: pending, at: Date()) == nil)
    }

    @Test func theAnnouncementNamesThePhaseAndWhatsLeft() {
        let cue = SpokenCuePlan.announcement(for: workout(end: now.addingTimeInterval(300)), at: now)
        #expect(cue == .phaseStart(label: "Work", length: 300))
        #expect(cue?.text?.hasPrefix("Work. ") == true)
    }

    @Test func theVoiceIsRememberedForTheSamePattern() throws {
        let suite = "spoken-cue-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = workout(end: now.addingTimeInterval(60))
        SpokenCuePreference.set(true, for: first, defaults: defaults)
        // A new run of the same phases and loops (new id) talks too.
        let again = workout(end: now.addingTimeInterval(600))
        #expect(again.id != first.id)
        #expect(SpokenCuePreference.isOn(for: again, defaults: defaults))
        // A different pattern doesn't.
        #expect(!SpokenCuePreference.isOn(for: workout(end: now, loops: 3), defaults: defaults))
        SpokenCuePreference.set(false, for: again, defaults: defaults)
        #expect(!SpokenCuePreference.isOn(for: first, defaults: defaults))
    }
}

import AVFoundation

extension SpokenCueTests {
    /// Every app language code resolves to a voice of that language (where one is
    /// installed) — "zh-Hans" isn't a locale code, but the system maps it to zh-CN.
    @Test func everyAppLanguageResolvesToAVoiceOfThatLanguage() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for code in ["en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt-BR", "ru", "id"] {
            let language = Locale(identifier: code).language.languageCode?.identifier ?? code
            guard voices.contains(where: { Locale(identifier: $0.language).language.languageCode?.identifier == language }) else { continue }
            let voice = AVSpeechSynthesisVoice(language: code)
            #expect(voice.map { Locale(identifier: $0.language).language.languageCode?.identifier } == language, "\(code)")
        }
    }
}
