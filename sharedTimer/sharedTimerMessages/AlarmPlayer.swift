//
//  AlarmPlayer.swift
//  sharedTimerMessages
//

import AudioToolbox
import AVFoundation
import Combine

/// Loops the bundled alarm.caf until stopped, like the native Clock app's
/// foreground "Time is up" alert. `.playback` category makes it ignore the
/// silent switch, same as system alarms/timers.
final class AlarmPlayer: ObservableObject {
    static let shared = AlarmPlayer()

    /// System sound ID for the fallback alert tone (undocumented but stable "Tweet
    /// Sent" chime — see AudioToolbox's known system sound ID list).
    private static let fallbackSystemSoundID: SystemSoundID = 1005

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
            AudioServicesPlaySystemSound(Self.fallbackSystemSoundID)
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

/// Repeats the device vibration until stopped — the "Vibrate when it ends" toggle's
/// engine. Deliberately independent of `AlarmPlayer`: the vibration toggle is its own
/// on/off, separate from the alarm toggle, so a finished timer with the alarm off but
/// vibration on must still buzz without any `AlarmPlayer` involvement.
final class VibrationPlayer: ObservableObject {
    static let shared = VibrationPlayer()

    @Published private(set) var isVibrating = false
    private var timer: Timer?

    private init() {}

    /// Foreground-only, like all vibration APIs — a backgrounded or terminated app
    /// cannot vibrate, so this only matters while the screen that called `start()`
    /// (or `checkForNewlyExpired`'s brief re-foreground window) is current.
    func start() {
        guard !isVibrating else { return }
        isVibrating = true
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isVibrating = false
    }
}
