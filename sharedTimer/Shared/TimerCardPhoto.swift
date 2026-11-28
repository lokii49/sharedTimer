//
//  TimerCardPhoto.swift
//  Shared (app, Messages, widget; excluded from the Clip and notification service)
//
//  The timer's own photo (N13) behind its Lock Screen Live Activity card, both the
//  AlarmKit card and the quiet one (owner's pick, 2026-11-28, mockups
//  https://claude.ai/artifact/MyGrrUUQn79f4Jh4NeYb1c). Hidden until Face ID unlocks
//  if the device test shows iOS tells a Live Activity it is locked; otherwise always
//  blurred — a locked phone shows its Lock Screen to anyone nearby.
//
//  Apple: an image larger than the Live Activity's presentation can stop the activity
//  from starting, and its data is capped at 4 KB. So the app writes small, card-shaped
//  copies (plain and pre-blurred) to the App Group, next to the timer's photo, and the
//  widget only reads them. Written wherever the photo changes (TimerPhotos.save, adopt,
//  remove) and backfilled for older photos by TimerPhotos.prune on foreground.
//

import CoreImage
import ImageIO
import SwiftUI
import UIKit

enum TimerCardPhoto {
    /// Card-shaped (the Lock Screen card is about 2.3:1) and below its size in pixels.
    static let pixelSize = CGSize(width: 900, height: 390)

    /// Show the plain photo once the phone is unlocked (Face ID recognized). Needs the
    /// device check that iOS hands a Live Activity `redactionReasons.privacy` while
    /// locked: until then only DEBUG builds try it, and releases always blur.
    #if DEBUG
    static let plainWhenUnlocked = true
    #else
    static let plainWhenUnlocked = false
    #endif

    /// Settable for tests only (they write to a temporary directory).
    nonisolated(unsafe) static var directory: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lokesh.sharedTimer")?
        .appendingPathComponent("TimerPhotos/Cards", isDirectory: true)

    static func url(for timerID: String, blurred: Bool) -> URL? {
        // Timer ids are UUID strings; anything else (path characters) never names a file.
        guard !timerID.isEmpty, timerID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory?.appendingPathComponent(blurred ? "\(timerID)-blur.jpg" : "\(timerID).jpg")
    }

    /// Widget side: the copy to draw, or nil (the card keeps its sky).
    static func image(for timerID: String, blurred: Bool) -> UIImage? {
        guard let url = url(for: timerID, blurred: blurred) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func exists(for timerID: String) -> Bool {
        url(for: timerID, blurred: true).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: Writing (app and Messages)

    /// Writes both copies from the timer's stored photo file. False when it can't.
    @discardableResult
    static func write(fromPhotoAt source: URL, for timerID: String) -> Bool {
        guard let plainURL = url(for: timerID, blurred: false), let blurURL = url(for: timerID, blurred: true),
              let image = UIImage(contentsOfFile: source.path), let cropped = cardCrop(image),
              let plain = cropped.jpegData(compressionQuality: 0.8),
              let blurred = blurredCopy(cropped)?.jpegData(compressionQuality: 0.75) else { return false }
        do {
            try FileManager.default.createDirectory(at: plainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plain.write(to: plainURL, options: .atomic)
            try blurred.write(to: blurURL, options: .atomic)
        } catch { return false }
        return true
    }

    static func remove(_ timerID: String) {
        for blurred in [false, true] {
            if let url = url(for: timerID, blurred: blurred) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Copies of timers no longer stored go; a kept timer whose photo has no copies yet
    /// (picked before this build) gets them. `photoURL` maps a timer id to its photo.
    static func prune(keeping timerIDs: Set<String>, photoURL: (String) -> URL?) {
        let fm = FileManager.default
        if let dir = directory, let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for file in files where file.hasSuffix(".jpg") {
                let id = file.hasSuffix("-blur.jpg") ? String(file.dropLast(9)) : String(file.dropLast(4))
                if !timerIDs.contains(id) { try? fm.removeItem(at: dir.appendingPathComponent(file)) }
            }
        }
        for id in timerIDs where !exists(for: id) {
            if let photo = photoURL(id), fm.fileExists(atPath: photo.path) { write(fromPhotoAt: photo, for: id) }
        }
    }

    /// Centre crop to the card's shape, scaled down to `pixelSize` (never up).
    static func cardCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let aspect = pixelSize.width / pixelSize.height
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > aspect {
            crop.size.width = (height * aspect).rounded(.down)
            crop.origin.x = ((width - crop.width) / 2).rounded(.down)
        } else {
            crop.size.height = (width / aspect).rounded(.down)
            crop.origin.y = ((height - crop.height) / 2).rounded(.down)
        }
        guard let piece = cg.cropping(to: crop) else { return nil }
        let scale = min(1, pixelSize.width / crop.width)
        let size = CGSize(width: (crop.width * scale).rounded(.down), height: (crop.height * scale).rounded(.down))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Strong enough that faces and writing can't be made out, only colours.
    static func blurredCopy(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let blur = input.clampedToExtent().applyingGaussianBlur(sigma: 18).cropped(to: input.extent)
        guard let cg = CIContext().createCGImage(blur, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The photo behind a Lock Screen card, darkened like the timer screen's so white text
/// reads on a bright picture. Blurred while iOS asks for privacy-redacted content (the
/// phone is locked) or always, until the device check passes (`plainWhenUnlocked`).
struct CardPhotoBackground: View {
    let timerID: String
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        let blurred = !TimerCardPhoto.plainWhenUnlocked || redaction.contains(.privacy)
        if let image = TimerCardPhoto.image(for: timerID, blurred: blurred) {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                       .init(color: .black.opacity(0.2), location: 0.45),
                                       .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
    }
}
