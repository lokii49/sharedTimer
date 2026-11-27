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
            // A lock with a slash: auto-lock is off. The sun (1.0.7) read as a dark/light
            // switch that did nothing (owner, 2026-11-27); on is filled and warm.
            Image(systemName: isOn ? "lock.slash.fill" : "lock.slash")
                .foregroundStyle(isOn ? KeepAwake.warm : Color.white)
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

enum KeepAwake {
    /// The sky's warm horizon colour, for the "on" state.
    static let warm = Color(red: 1.0, green: 0.82, blue: 0.45)
}

private struct KeepAwakeModifier: ViewModifier {
    @Binding var isOn: Bool
    let finished: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// The short confirmation under the toolbar ("Screen stays on" / "Screen can sleep").
    @State private var confirmation: LocalizedStringKey?
    @State private var confirmationTask: Task<Void, Never>?
    /// Set as the screen goes away, so that automatic off isn't announced.
    @State private var leaving = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let confirmation {
                    Text(confirmation)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // VoiceOver already hears the announcement below.
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: confirmation)
            .onChange(of: isOn) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
                // Only the person's own tap is confirmed — not the automatic off at the
                // finish, in the background or when leaving the screen.
                guard on || (!finished && !leaving && scenePhase == .active) else { return }
                UIAccessibility.post(notification: .announcement,
                                     argument: on ? String(localized: "Screen stays on") : String(localized: "Screen can sleep"))
                confirmationTask?.cancel()
                confirmation = on ? "Screen stays on" : "Screen can sleep"
                confirmationTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    confirmation = nil
                }
            }
            .onChange(of: finished) { _, done in if done { isOn = false } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { isOn = false } }
            .onAppear { leaving = false }
            .onDisappear {
                leaving = true
                isOn = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
    }
}
