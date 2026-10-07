//
//  NewTimerSheet.swift
//  sharedTimer
//

import SwiftUI
import UIKit

struct NewTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String = ""
    @State private var kind: TimerKind
    @State private var minutes: Double = 5
    @State private var targetDate: Date = Date().addingTimeInterval(86400)
    @State private var alarmEnabled = true
    @State private var vibrationEnabled = true
    @FocusState private var labelFocused: Bool
    @State private var recents: [RecentTimer] = RecentTimersStore.all()

    let onCreate: (TimerPayload) -> Void

    init(initialKind: TimerKind = .timer, onCreate: @escaping (TimerPayload) -> Void) {
        self._kind = State(initialValue: initialKind)
        self.onCreate = onCreate
    }

    /// Live preview of the sky this timer will get.
    private var previewPayload: TimerPayload {
        TimerPayload.compose(label: label.isEmpty ? (kind == .timer ? "Timer" : "Countdown") : label,
                             kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                // One tap starts a recent timer as-is (timers only — a countdown
                // targets a date). Long-press a chip to forget it.
                if kind == .timer && !recents.isEmpty {
                    Section {
                        ChipFlowLayout(spacing: 8) {
                            ForEach(recents) { recent in
                                Button {
                                    onCreate(recent.payload())
                                    dismiss()
                                } label: {
                                    Text(recent.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(.white.opacity(0.14), in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        RecentTimersStore.remove(id: recent.id)
                                        recents = RecentTimersStore.all()
                                        RecentTimersSync.refresh()
                                    } label: {
                                        Label("Remove from Recent", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Recent")
                    }
                }

                Section {
                    SkyCard(payload: previewPayload, date: Date())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                TimerFieldsView(
                    label: $label,
                    kind: $kind,
                    minutes: $minutes,
                    targetDate: $targetDate,
                    alarmEnabled: $alarmEnabled,
                    vibrationEnabled: $vibrationEnabled,
                    labelFocused: $labelFocused,
                    kindLocked: true
                )
            }
            .scrollContentBackground(.hidden)
            .background(Sky.room)
            .navigationTitle(kind == .timer ? "New Timer" : "New Countdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        onCreate(TimerPayload.compose(label: label, kind: kind, minutes: minutes, targetDate: targetDate, alarmEnabled: alarmEnabled, vibrationEnabled: vibrationEnabled))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

/// Left-aligned wrapping row of chips — fills a line, then wraps to the next.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
