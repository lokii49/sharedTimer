//
//  SettingsView.swift
//  sharedTimer
//
//  "Sky Stack" Settings (direction B of three pitched mockups, chosen 2026-10-18,
//  https://claude.ai/artifact/Bne46iEsrKYGREVFPaqoR1): each section is a sky card like
//  the timer rows. Card skies are fixed per section, never timed, so nothing drains.
//  Main app only.
//

import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = DisplayNameStore.name
    @State private var editingName = false
    @State private var nameInput = ""
    @State private var tone = AlarmTone.selected
    @State private var showingWhatsNew = false
    @State private var preview: AVAudioPlayer?

    private static let privacyURL = URL(string: "https://mirrornotes.org/timer/privacy")!
    private static let supportURL = URL(string: "mailto:hello@mirrornotes.org?subject=Timer%20support")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    nameCard
                    toneCard
                    whatsNewCard
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Sky.room)
            .navigationTitle("Settings")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Your name", isPresented: $editingName) {
            TextField("Your name", text: $nameInput)
            Button("Save") {
                let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    DisplayNameStore.name = trimmed
                    name = trimmed
                }
            }
            if name != nil {
                Button("Clear", role: .destructive) {
                    DisplayNameStore.name = nil
                    DisplayNameStore.declined = true
                    name = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown to people you share timers with. Leave it empty to show “Someone”.")
        }
        .fullScreenCover(isPresented: $showingWhatsNew) {
            WhatsNewView { showingWhatsNew = false }
        }
        .onChange(of: tone) { _, newTone in
            AlarmTone.selected = newTone
            play(newTone)
            // Armed AlarmKit alarms and notifications carry the old tone; re-arm them.
            for payload in TimerStore.loadAll() { TimerArming.arm(payload) }
        }
        .onDisappear { preview?.stop() }
    }

    // MARK: Cards

    private var nameCard: some View {
        SettingsCard(colors: Sky.dusk.stops(drain: 0)) {
            Text("Your name").skyLabel(11).opacity(0.8)
            HStack(alignment: .center) {
                Text(name ?? String(localized: "Not set"))
                    .font(.system(size: 34, weight: .thin))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(name == nil ? "Set" : "Change") {
                    nameInput = name ?? ""
                    editingName = true
                }
                .buttonStyle(.glassPill)
            }
            // The exact sentence people receive explains the setting better than a footnote.
            Text("\(name ?? String(localized: "Someone")) paused Pasta · 4:12 left")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.16), in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16))
                .accessibilityLabel("Preview: \(name ?? String(localized: "Someone")) paused Pasta")
        }
    }

    private var toneCard: some View {
        SettingsCard(colors: Sky.ember.stops(drain: 0)) {
            Text("Alarm sound · this iPhone").skyLabel(11).opacity(0.8)
            FlowChips(tones: AlarmTone.allCases, selected: $tone) { play($0) }
            Text("People you share with hear their own choice.")
                .font(.footnote)
                .opacity(0.75)
        }
    }

    private var whatsNewCard: some View {
        SettingsCard(colors: Sky.night.stops(drain: 0.6)) {
            Text("What's New").skyLabel(11).opacity(0.8)
            HStack(spacing: 12) {
                Text("Take the tour of this version again.")
                    .font(.subheadline)
                Spacer()
                Button("Replay") { showingWhatsNew = true }
                    .buttonStyle(.glassPill)
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(colors: Sky.overcast) {
            Text("About").skyLabel(11).opacity(0.8)
            VStack(spacing: 0) {
                aboutRow { Text("Version") } trailing: { Text(Self.versionText).monospacedDigit() }
                Divider().overlay(.white.opacity(0.15))
                Link(destination: Self.privacyURL) {
                    aboutRow { Text("Privacy Policy") } trailing: { Image(systemName: "arrow.up.right") }
                }
                Divider().overlay(.white.opacity(0.15))
                Link(destination: Self.supportURL) {
                    aboutRow { Text("Support") } trailing: { Text(verbatim: "hello@mirrornotes.org") }
                }
                .accessibilityHint("Writes an email to hello@mirrornotes.org")
            }
        }
    }

    private func aboutRow<L: View, T: View>(@ViewBuilder _ leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            leading()
            Spacer()
            trailing().opacity(0.8)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    // MARK: Tone preview

    private func play(_ tone: AlarmTone) {
        preview?.stop()
        guard let url = tone.url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        // .playback so the preview is heard with the silent switch on, like the real alarm.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        preview = player
    }
}

/// A fixed sky behind one Settings section — SkyCard's shape without the timer.
private struct SettingsCard<Content: View>: View {
    let colors: [Color]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }
}

/// Tone chips: one row when they fit, otherwise a 2×2 grid (one column at the
/// largest text sizes).
private struct FlowChips: View {
    let tones: [AlarmTone]
    @Binding var selected: AlarmTone
    let onReplay: (AlarmTone) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading),
                                     count: typeSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: 8) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(tones) { tone in
            let isSelected = tone == selected
            Button {
                if isSelected { onReplay(tone) } else { selected = tone }
            } label: {
                Label {
                    Text(tone.title)
                } icon: {
                    Image(systemName: isSelected ? "checkmark" : "waveform")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color(red: 0.23, green: 0.08, blue: 0.19) : .white)
                .background(isSelected ? AnyShapeStyle(.white.opacity(0.92)) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0 : 0.18)))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(isSelected ? "Plays it again" : "Selects and plays this tone")
        }
    }
}
