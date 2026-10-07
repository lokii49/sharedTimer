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
    @State private var preparedURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                SkyCard(payload: payload, date: Date())
                    .padding(.horizontal, 20)

                if let preparedURL {
                    ShareLink(item: preparedURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassPill)
                    .padding(.horizontal, 20)
                } else {
                    ProgressView("Preparing link…")
                }

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
        .task {
            let current = (TimerStore.loadAll().first { $0.id == payload.id } ?? payload).advancedSequence()
            let shareURL: URL? = await withCheckedContinuation { continuation in
                CloudSyncController.createShare(for: current) { continuation.resume(returning: $0) }
            }
            var components = URLComponents(url: current.url(), resolvingAgainstBaseURL: false)!
            if let shareURL {
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ckshare", value: shareURL.absoluteString)]
            }
            preparedURL = components.url ?? current.url()
        }
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
                    Text(payload.recurrence != nil ? "Shared yearly countdown from a link" : payload.sequence == nil ? "Shared timer from a link" : "Shared sequence from a link")
                        .font(.subheadline)
                        .foregroundStyle(Sky.roomInk)
                    if let sequence = payload.sequence {
                        Text("\(sequence.phases.count) phases · \(sequence.loopCount) loops")
                            .font(.footnote).foregroundStyle(Sky.roomInk)
                    } else if payload.kind == .timer {
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
