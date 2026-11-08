//
//  SmallActivityTile.swift
//  sharedTimerWidget
//
//  The `.small` Live Activity family — Apple Watch Smart Stack and CarPlay (1.0.7,
//  mockup D4 · A): the timer's sky as a tile, small-caps label over thin live digits.
//  No buttons (that family is glanceable; a tap opens the app). Both Live Activities —
//  AlarmKit's and the custom quiet one — opt in with `.supplementalActivityFamilies`.
//

import SwiftUI
import WidgetKit

/// Shows `small` in the `.small` activity family and `medium` everywhere else (the
/// iPhone Lock Screen banner).
struct ActivityFamilySwitch<Medium: View, Small: View>: View {
    @Environment(\.activityFamily) private var family
    @ViewBuilder let medium: () -> Medium
    @ViewBuilder let small: () -> Small

    var body: some View {
        switch family {
        case .small: small()
        default: medium()
        }
    }
}

struct SmallActivityTile<Digits: View>: View {
    let label: String
    let symbol: String
    let sky: LinearGradient
    @ViewBuilder let digits: () -> Digits

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label).skyLabel(10).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
            digits()
                .font(.system(size: 26, weight: .light))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
        .background(sky)
        .accessibilityElement(children: .combine)
    }
}
