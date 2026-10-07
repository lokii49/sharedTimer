//
//  ShareSheets.swift
//  sharedTimer
//

import SwiftUI
import UIKit

/// Sheet shown from a row's context-menu Share action. `ShareLink` inside `.contextMenu`
/// is unreliable, so this presents the timer's sky with the real `ShareLink` on it.
struct ShareTimerSheet: View {
    let payload: TimerPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                SkyCard(payload: payload, date: Date())
                    .padding(.horizontal, 20)

                ShareLink(item: payload.url()) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .padding(.horizontal, 20)

                Spacer()
            }
            .padding(.top, 26)
            .background(Sky.room)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Confirmation sheet for a timer arriving via universal link while the full app is
/// already installed — its sky, then what it is, then the choice.
struct AddSharedTimerSheet: View {
    let payload: TimerPayload
    let onAdd: (TimerPayload) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                SkyCard(payload: payload, date: Date())
                    .padding(.horizontal, 20)

                VStack(spacing: 6) {
                    Text("Shared timer from a link")
                        .font(.subheadline)
                        .foregroundStyle(Sky.roomInk)
                    if payload.kind == .timer {
                        Text("Ends at \(payload.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(Sky.roomInk)
                    } else {
                        Text("Counting down to \(TimeFormat.targetDate(payload.endDate))")
                            .font(.footnote)
                            .foregroundStyle(Sky.roomInk)
                    }
                }

                Spacer()

                Button {
                    onAdd(payload)
                } label: {
                    Text("Add to My Timers")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPill)
                .padding(.horizontal, 20)

                Button("Not Now") {
                    onDismiss()
                }
                .font(.footnote)
                .foregroundStyle(Sky.roomInk)
                .padding(.bottom, 16)
            }
            .padding(.top, 26)
            .background(Sky.room)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    ContentView()
}
