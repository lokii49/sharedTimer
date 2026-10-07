//
//  StartRecentTimerControl.swift
//  sharedTimerWidget
//
//  Control Center / Lock Screen / Action button control: one tap starts the most
//  recent timer ("Start Pasta 8m") without opening the app. The button's action is
//  StartRecentTimerIntent (Shared/LiveActivityIntents.swift), which the system runs in
//  the app's process — AlarmKit isn't available here in the extension. The title is
//  read from RecentTimersStore; the app reloads this control whenever the recents
//  change (RecentTimersSync).
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartRecentTimerControl: ControlWidget {
    static let kind = "StartRecentTimerControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { recent in
            ControlWidgetButton(action: StartRecentTimerIntent()) {
                Label(recent.map { "Start \($0.title)" } ?? "Start 5m Timer", systemImage: "timer")
            }
        }
        .displayName("Start Recent Timer")
        .description("Starts your most recent timer without opening the app.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: RecentTimer? {
            RecentTimer(label: "Pasta", duration: 8 * 60, alarmEnabled: true, vibrationEnabled: true)
        }

        func currentValue() async throws -> RecentTimer? {
            RecentTimersStore.all().first
        }
    }
}
