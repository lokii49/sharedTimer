//
//  AlarmPlayerTests.swift
//  sharedTimerTests
//
//  The audio session now comes up on a background queue (AVAudioSession hang risk);
//  playback still has to start, and a Stop that lands first has to win.
//

import Foundation
import Testing
@testable import sharedTimer

@MainActor
@Suite(.serialized)
struct AlarmPlayerTests {
    @Test func startKeepsPlayingOnceTheSessionIsUp() async {
        let player = AlarmPlayer.shared
        player.start()
        #expect(player.isPlaying)
        try? await Task.sleep(for: .milliseconds(800))
        // Still playing: the session activated and the loop began (a failed activation
        // would have fallen back and reset isPlaying).
        #expect(player.isPlaying)
        player.stop()
        #expect(!player.isPlaying)
    }

    @Test func aStopBeforeTheSessionIsUpWins() async {
        let player = AlarmPlayer.shared
        player.start()
        player.stop()
        try? await Task.sleep(for: .milliseconds(800))
        #expect(!player.isPlaying)
    }
}
