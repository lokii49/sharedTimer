//
//  AlarmPlayer.swift
//  sharedTimerClip
//

import AudioToolbox
import AVFoundation
import Combine

/// Loops the bundled alarm.caf until stopped, like the native Clock app's
/// foreground "Time is up" alert. `.playback` category makes it ignore the
/// silent switch, same as system alarms/timers.
final class AlarmPlayer: ObservableObject {
    static let shared = AlarmPlayer()

    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    private init() {}

    func start() {
        guard !isPlaying else { return }
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.play()
            self.player = player
            isPlaying = true
        } catch {
            print("SharedTimer alarm playback failed: \(error)")
            player = nil
            isPlaying = false
            // No sound is worse than the wrong sound: if the .playback session never
            // activates, fall back to a system alert tone + vibration rather than
            // finishing a timer in total silence.
            AudioServicesPlaySystemSound(1005)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
