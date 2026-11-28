//
//  TimerPhotos.swift
//  Shared (app + Messages; excluded from the Clip, widget and notification service)
//
//  N13 photo backgrounds (owner's pick A, 2026-11-28, https://claude.ai/artifact/Ah5VuSJMj9Akm63cBUKe38):
//  a timer's own photo in place of its sky, on its list card and its screen. Picked with
//  the system PhotosPicker (runs outside the app — no photo-library permission, no usage
//  string). Downscaled to a JPEG file in the App Group, one per timer id; never uploaded,
//  never in a link, share preview, iCloud, widget or the Watch — the privacy label stays
//  "Data Not Collected". Messages compiles this only because the shared Edit sheet does;
//  it never shows the picker (`EditTimerSheet.showsTagsAndNote`).
//

import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TimerPhotos {
    static let changed = Notification.Name("SharedTimerPhotosChanged")
    static let maxPixel: CGFloat = 1600
    nonisolated(unsafe) static var directory: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lokesh.sharedTimer")?
        .appendingPathComponent("TimerPhotos", isDirectory: true)
    private static let cache = NSCache<NSString, UIImage>()

    static func url(for timerID: String) -> URL? {
        // Timer ids are UUID strings; anything else (path characters) never names a file.
        guard timerID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !timerID.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(timerID).jpg")
    }

    static func has(_ timerID: String) -> Bool {
        url(for: timerID).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Decoded once and cached: list cards redraw every second.
    static func image(for timerID: String) -> UIImage? {
        if let hit = cache.object(forKey: timerID as NSString) { return hit }
        guard let url = url(for: timerID), let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: timerID as NSString)
        return image
    }

    /// Stores a picked photo (any format ImageIO reads), downscaled. False when it can't
    /// be read or written.
    @discardableResult
    static func save(_ data: Data, for timerID: String) -> Bool {
        guard let url = url(for: timerID), let jpeg = downscaledJPEG(data) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: url, options: .atomic)
        } catch { return false }
        cache.removeObject(forKey: timerID as NSString)
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: timerID) }
        return true
    }

    static func remove(_ timerID: String) {
        guard let url = url(for: timerID) else { return }
        try? FileManager.default.removeItem(at: url)
        cache.removeObject(forKey: timerID as NSString)
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: timerID) }
    }

    /// Photos of timers no longer stored. App only, complete store only (see the caller).
    static func prune(keeping timerIDs: Set<String>) {
        guard let dir = directory, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasSuffix(".jpg") {
            let id = String(file.dropLast(4))
            if !timerIDs.contains(id) { remove(id) }
        }
    }

    /// The longest side at most `maxPixel`, as JPEG — without decoding the full image.
    static func downscaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.82)
    }
}

#if DEBUG && targetEnvironment(simulator)
extension TimerPhotos {
    /// A bright sky-sand-sea picture, for screenshots of text over a light photo.
    static func seedForScreenshots(timerID: String) {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.6, green: 0.83, blue: 0.96, alpha: 1), UIColor(red: 0.97, green: 0.89, blue: 0.71, alpha: 1),
                          UIColor(red: 0.91, green: 0.76, blue: 0.49, alpha: 1)].map(\.cgColor) as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 0.72])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.72), options: [.drawsAfterEndLocation])
            UIColor(red: 0.18, green: 0.44, blue: 0.56, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.72, width: size.width, height: size.height * 0.28))
            UIColor.white.withAlphaComponent(0.95).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 820, y: 90, width: 160, height: 160))
        }
        if let data = image.pngData() { save(data, for: timerID) }
    }
}
#endif

/// A photo filling its frame, darkened top and bottom so white text stays readable on a
/// bright picture.
struct PhotoBackdrop: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
        }
        .overlay {
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                   .init(color: .black.opacity(0.15), location: 0.4),
                                   .init(color: .black.opacity(0.2), location: 0.6),
                                   .init(color: .black.opacity(0.6), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}


/// "Background: Sky / Photo" for New Timer and Edit. `preview` is what's chosen now
/// (nil = the sky); picking loads the photo's data, Remove goes back to the sky.
struct PhotoBackgroundRow: View {
    let preview: UIImage?
    let onPick: (Data) -> Void
    let onRemove: () -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: Sky.ember.stops(drain: 0.2), startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Background")
                Text(preview == nil ? String(localized: "Sky") : String(localized: "Photo"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if preview != nil {
                Button("Remove", role: .destructive) { onRemove() }
                    .buttonStyle(.borderless)
            }
            PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                Text(preview == nil ? String(localized: "Choose Photo…") : String(localized: "Change…"))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("photoPicker")
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self) { onPick(data) }
                item = nil
            }
        }
    }
}
