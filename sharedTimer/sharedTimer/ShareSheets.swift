//
//  ShareSheets.swift
//  sharedTimer
//

import SwiftUI
import UIKit
import CloudKit
import CoreImage.CIFilterBuiltins

/// Sheet shown from a row's context-menu Share action. `ShareLink` inside `.contextMenu`
/// is unreliable, so this presents the timer's sky with the real `ShareLink` on it.
struct ShareTimerSheet: View {
    let payload: TimerPayload
    @Environment(\.dismiss) private var dismiss
    @State private var preparedURL: URL?
    /// The same timer without its iCloud share: view-only, so a QR code shown across a
    /// room (or photographed) can't be used to pause or extend the timer for everyone.
    @State private var snapshotURL: URL?
    /// Whether the link carries a CloudKit share (stays in sync) or is a snapshot.
    @State private var isLive = false
    @State private var previewImage: Image?
    @State private var showingQR = false
    @State private var cloudShare: CloudShareItem?
    @State private var loadingShare = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SkyCard(payload: payload, date: Date())
                        .padding(.horizontal, 20)

                    if let preparedURL {
                        Label(isLive ? "Live link · changes sync for everyone" : "Snapshot · won't update after sending",
                              systemImage: isLive ? "icloud" : "camera.viewfinder")
                            .font(.footnote)
                            .foregroundStyle(Sky.roomInk)
                            .accessibilityHint(isLive ? "" : "iCloud sharing isn't available right now")

                        ShareLink(item: preparedURL,
                                  subject: Text(payload.label),
                                  message: Text(payload.shareMessage),
                                  preview: SharePreview(payload.label, image: previewImage ?? Image(systemName: "timer"))) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassPill)
                        .padding(.horizontal, 20)

                        HStack(spacing: 12) {
                            if let snapshotURL, QRCode.fits(snapshotURL) {
                                Button {
                                    withAnimation { showingQR.toggle() }
                                } label: {
                                    Label(showingQR ? "Hide QR Code" : "QR Code", systemImage: "qrcode")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassPill)
                            }
                            if isLive {
                                Button {
                                    manageSharing()
                                } label: {
                                    Label("Manage Sharing", systemImage: "person.2")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassPill)
                                .disabled(loadingShare)
                            }
                        }
                        .padding(.horizontal, 20)

                        if showingQR, let snapshotURL, let image = QRCode.image(for: snapshotURL) {
                            VStack(spacing: 8) {
                                Image(uiImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 220, height: 220)
                                    .padding(12)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                                    .accessibilityLabel("QR code for \(payload.label)")
                                Text("View-only: people who scan this see the countdown but can't change it, and it won't follow later pauses or extensions.")
                                    .font(.footnote)
                                    .foregroundStyle(Sky.roomInk)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                            }
                            .transition(.opacity)
                        }
                    } else {
                        ProgressView("Preparing link…")
                    }
                }
                .padding(.top, 26)
                .padding(.bottom, 20)
            }
            .background(Sky.room)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $cloudShare) { item in
            CloudSharingView(item: item, title: payload.label) {
                CloudSyncController.didStopSharing(timerID: payload.id)
                isLive = false
                // Snapshot only: re-preparing a live link here silently created a fresh
                // read-write share right after the person stopped sharing.
                Task { await prepare(live: false) }
            }
            .ignoresSafeArea()
        }
        .task {
            previewImage = renderPreview()
            await prepare()
        }
    }

    private func prepare(live: Bool = true) async {
        let current = (TimerStore.loadAll().first { $0.id == payload.id } ?? payload).advancedSequence()
        let shareURL: URL? = live ? await withCheckedContinuation { continuation in
            CloudSyncController.createShare(for: current) { continuation.resume(returning: $0) }
        } : nil
        var components = URLComponents(url: current.url(), resolvingAgainstBaseURL: false)!
        if let shareURL {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "ckshare", value: shareURL.absoluteString)]
        }
        isLive = shareURL != nil
        snapshotURL = current.url()
        preparedURL = components.url ?? current.url()
    }

    private func manageSharing() {
        loadingShare = true
        CloudSyncController.fetchShare(for: payload) { result in
            loadingShare = false
            if let (share, container) = result { cloudShare = CloudShareItem(share: share, container: container) }
        }
    }

    /// The sky card as the share sheet's thumbnail, instead of a generic link icon.
    @MainActor private func renderPreview() -> Image? {
        let renderer = ImageRenderer(content: SkyCard(payload: payload, date: Date()).frame(width: 340))
        renderer.scale = 3
        return renderer.uiImage.map(Image.init(uiImage:))
    }
}

/// QR codes for in-person sharing (CoreImage, no package). Always the snapshot link,
/// never the iCloud share — see `ShareTimerSheet.snapshotURL`. Long links (a big
/// sequence) don't fit a scannable code, so the button hides.
enum QRCode {
    private static let maxBytes = 1_200

    static func fits(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= maxBytes
    }

    static func image(for url: URL) -> UIImage? {
        guard fits(url) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct CloudShareItem: Identifiable {
    let share: CKShare
    let container: CKContainer
    var id: CKRecord.ID { share.recordID }
}

/// Apple's participants screen: see who has the timer, remove someone, or stop sharing.
struct CloudSharingView: UIViewControllerRepresentable {
    let item: CloudShareItem
    let title: String
    let onStopSharing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(title: title, onStopSharing: onStopSharing) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: item.share, container: item.container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite, .allowReadOnly, .allowPublic]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String
        let onStopSharing: () -> Void

        init(title: String, onStopSharing: @escaping () -> Void) {
            self.title = title
            self.onStopSharing = onStopSharing
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            print("SharedTimer: UICloudSharingController failed to save share: \(error)")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onStopSharing()
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
