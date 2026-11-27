//
//  AlarmPlayer.swift
//  Shared
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
    /// Bumped by every start/stop (main thread), so a start whose session came up after
    /// a Stop doesn't begin playing.
    private var generation = 0

    /// Activating/deactivating the audio session can block for a while; on the main
    /// thread Xcode flags it ("AVAudioSession Hang Risk"). The async activate/deactivate
    /// API is iOS 27-only (deployment target 26.1), so it runs on this queue instead,
    /// in call order. Shared with Settings' tone preview.
    static let sessionQueue = DispatchQueue(label: "com.lokesh.sharedTimer.audioSession", qos: .userInitiated)

    private init() {}

    func start() {
        guard !isPlaying else { return }
        guard let url = AlarmTone.selected.url ?? Bundle.main.url(forResource: "alarm", withExtension: "caf") else { return }
        isPlaying = true
        generation += 1
        let token = generation
        Self.sessionQueue.async {
            var activated = true
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("SharedTimer alarm session failed: \(error)")
                activated = false
            }
            DispatchQueue.main.async { [self] in
                guard token == generation, isPlaying else { return }   // stopped meanwhile
                if activated, let player = try? AVAudioPlayer(contentsOf: url) {
                    player.numberOfLoops = -1
                    player.play()
                    self.player = player
                    return
                }
                isPlaying = false
                // No sound is worse than the wrong sound: if the .playback session never
                // activates, fall back to a system alert tone + vibration rather than
                // finishing a timer in total silence.
                AudioServicesPlaySystemSound(Self.fallbackSystemSoundID)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        isPlaying = false
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Repeats the device vibration until stopped — the "Vibrate" toggle's
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
