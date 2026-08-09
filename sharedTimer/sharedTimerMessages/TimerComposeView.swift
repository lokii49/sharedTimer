//
//  TimerComposeView.swift
//  sharedTimerMessages
//

import SwiftUI

struct TimerComposeView: View {
    @State private var label: String = "Timer"
    @State private var minutes: Double = 5

    let onStart: (TimerPayload) -> Void

    private let presets: [Double] = [1, 3, 5, 10, 15, 30, 60]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("New Shared Timer")
                    .font(.headline)

                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Text("\(Int(minutes)) min")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Slider(value: $minutes, in: 1...120, step: 1)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                    ForEach(presets, id: \.self) { m in
                        Button("\(Int(m))m") { minutes = m }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)

                Button {
                    let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload = TimerPayload(label: name.isEmpty ? "Timer" : name, duration: minutes * 60)
                    onStart(payload)
                } label: {
                    Text("Start & Share")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
}
