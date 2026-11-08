//
//  KeepAwake.swift
//  sharedTimerClip
//
//  "Keep screen awake" (D3, 1.0.7 mockup direction A): a sun toggle on a running
//  timer's screen. A copy of sharedTimer/KeepAwake.swift (keep the two in sync):
//  `UIApplication.shared` is unavailable in app extensions, so this can't live in
//  Shared/ (Messages and the widget compile that). Never persisted: it turns itself
//  off when the screen goes away, the app leaves the foreground, or the timer finishes.
//

import SwiftUI
import UIKit

struct KeepAwakeButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "sun.max.fill" : "sun.max")
        }
        .accessibilityLabel("Keep Screen On")
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

extension View {
    /// Applies `isOn` to the idle timer and switches it off again when this view
    /// disappears, the scene leaves the foreground or `finished` becomes true.
    func keepsScreenAwake(_ isOn: Binding<Bool>, finished: Bool) -> some View {
        modifier(KeepAwakeModifier(isOn: isOn, finished: finished))
    }
}

private struct KeepAwakeModifier: ViewModifier {
    @Binding var isOn: Bool
    let finished: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: isOn) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
                if on { UIAccessibility.post(notification: .announcement, argument: String(localized: "Screen stays on")) }
            }
            .onChange(of: finished) { _, done in if done { isOn = false } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { isOn = false } }
            .onDisappear {
                isOn = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}
