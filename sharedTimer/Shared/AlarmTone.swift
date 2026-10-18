//
//  AlarmTone.swift
//  Shared
//
//  The finish tone picked in Settings. A local preference (App Group, so the Messages
//  extension and App Clip on this phone use it too) — never on the wire or in CloudKit:
//  everyone sharing a timer hears their own choice.
//
//  Compiled by sharedTimer, sharedTimerMessages and sharedTimerClip — the targets that
//  bundle the .caf files and play/schedule the alarm. Excluded from the Widget.
//

import Foundation

enum AlarmTone: String, CaseIterable, Identifiable {
    case classic, glass, ember, dawn

    var id: String { rawValue }

    /// Bundled in each of the three targets' folders, same format as alarm.caf
    /// (mono 44.1 kHz 16-bit, ~3 s) so AlarmKit, notifications and AVAudioPlayer all
    /// accept it.
    var fileName: String {
        self == .classic ? "alarm.caf" : "alarm_\(rawValue).caf"
    }

    var title: LocalizedStringResource {
        switch self {
        case .classic: return "Classic"
        case .glass: return "Glass"
        case .ember: return "Ember"
        case .dawn: return "Dawn"
        }
    }

    private static let key = "alarmTone"

    static var selected: AlarmTone {
        get {
            UserDefaults(suiteName: "group.com.lokesh.sharedTimer")?.string(forKey: key).flatMap(AlarmTone.init(rawValue:)) ?? .classic
        }
        set {
            UserDefaults(suiteName: "group.com.lokesh.sharedTimer")?.set(newValue.rawValue, forKey: key)
        }
    }

    var url: URL? {
        Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: "caf")
    }
}
