//
//  TimerPhotosTests.swift
//  sharedTimerTests
//
//  N13: photos are downscaled, cached, removed and pruned — in a private directory.
//

import Foundation
import Testing
import UIKit
@testable import sharedTimer

@Suite(.serialized)
struct TimerPhotosTests {
    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let saved = TimerPhotos.directory, savedCards = TimerCardPhoto.directory
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
        TimerPhotos.directory = dir
        // Card copies too: prune would otherwise delete the real App Group's.
        TimerCardPhoto.directory = dir.appendingPathComponent("Cards", isDirectory: true)
        defer { TimerPhotos.directory = saved; TimerCardPhoto.directory = savedCards; try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func bigImageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000)) }
            .pngData()!
    }

    @Test func aPickedPhotoIsDownscaledAndStoredPerTimer() throws {
        try withTempDirectory { _ in
            let id = UUID().uuidString
            #expect(!TimerPhotos.has(id))
            #expect(TimerPhotos.save(bigImageData(), for: id))
            #expect(TimerPhotos.has(id))
            let image = try #require(TimerPhotos.image(for: id))
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            #expect(longest <= TimerPhotos.maxPixel)
            TimerPhotos.remove(id)
            #expect(!TimerPhotos.has(id))
            #expect(TimerPhotos.image(for: id) == nil)   // cache dropped too
        }
    }

    @Test func pruneKeepsOnlyStoredTimers() throws {
        try withTempDirectory { _ in
            let kept = UUID().uuidString, gone = UUID().uuidString
            TimerPhotos.save(bigImageData(), for: kept)
            TimerPhotos.save(bigImageData(), for: gone)
            TimerPhotos.prune(keeping: [kept])
            #expect(TimerPhotos.has(kept))
            #expect(!TimerPhotos.has(gone))
        }
    }

    @Test func oddIDsAndUnreadableDataNeverWriteAFile() throws {
        try withTempDirectory { dir in
            #expect(TimerPhotos.url(for: "../escape") == nil)
            #expect(TimerPhotos.url(for: "") == nil)
            #expect(!TimerPhotos.save(Data("not an image".utf8), for: UUID().uuidString))
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
        }
    }

    @Test func aPhotoFollowsItsNameAndLength() throws {
        try withTempDirectory { _ in
            let first = UUID().uuidString, again = UUID().uuidString
            TimerPhotos.save(bigImageData(), for: first)
            TimerPhotos.adopt(timerID: first, recentKey: "Trip|2592000")
            // The first timer leaves the list (pruned); the remembered photo stays.
            TimerPhotos.prune(keeping: [])
            #expect(!TimerPhotos.has(first))
            TimerPhotos.adopt(timerID: again, recentKey: "Trip|2592000")
            #expect(TimerPhotos.has(again))
            // Removing it on the new run removes the remembered one too.
            TimerPhotos.remove(again)
            TimerPhotos.remember(timerID: again, recentKey: "Trip|2592000")
            let third = UUID().uuidString
            TimerPhotos.adopt(timerID: third, recentKey: "Trip|2592000")
            #expect(!TimerPhotos.has(third))
        }
    }

    // MARK: Card copies for the Live Activity card (1.0.11)

    @Test func savingAPhotoWritesSmallCardShapedCopies() throws {
        try withTempDirectory { _ in
            let id = UUID().uuidString
            #expect(!TimerCardPhoto.exists(for: id))
            #expect(TimerPhotos.save(bigImageData(), for: id))
            #expect(TimerCardPhoto.exists(for: id))
            for blurred in [false, true] {
                let card = try #require(TimerCardPhoto.image(for: id, blurred: blurred))
                let width = card.size.width * card.scale, height = card.size.height * card.scale
                // Apple: never larger than the card, or the activity may not start.
                #expect(width <= TimerCardPhoto.pixelSize.width && height <= TimerCardPhoto.pixelSize.height)
                #expect(abs(width / height - TimerCardPhoto.pixelSize.width / TimerCardPhoto.pixelSize.height) < 0.02)
            }
            TimerPhotos.remove(id)
            #expect(!TimerCardPhoto.exists(for: id))
            #expect(TimerCardPhoto.image(for: id, blurred: false) == nil)
        }
    }

    @Test func pruneDropsOrphanedCardsAndBackfillsOlderPhotos() throws {
        try withTempDirectory { _ in
            let kept = UUID().uuidString, gone = UUID().uuidString
            TimerPhotos.save(bigImageData(), for: kept)
            TimerPhotos.save(bigImageData(), for: gone)
            // A photo picked before card copies existed.
            TimerCardPhoto.remove(kept)
            #expect(!TimerCardPhoto.exists(for: kept))
            TimerPhotos.prune(keeping: [kept])
            #expect(TimerCardPhoto.exists(for: kept))
            #expect(!TimerCardPhoto.exists(for: gone))
            #expect(TimerCardPhoto.image(for: gone, blurred: false) == nil)
        }
    }

    @Test func aRememberedPhotoGivesTheNewTimerItsCards() throws {
        try withTempDirectory { _ in
            let first = UUID().uuidString, second = UUID().uuidString, key = "Pasta 8m \(UUID().uuidString)"
            TimerPhotos.save(bigImageData(), for: first)
            TimerPhotos.adopt(timerID: first, recentKey: key)
            TimerPhotos.adopt(timerID: second, recentKey: key)
            #expect(TimerPhotos.has(second))
            #expect(TimerCardPhoto.exists(for: second))
        }
    }

    @Test func blurredCardHidesDetail() throws {
        // Black and white stripes: blurred, neighbouring pixels end up close in value.
        let stripes = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 390), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { ctx in
                for x in stride(from: 0, to: 900, by: 8) {
                    (x / 8 % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                    ctx.fill(CGRect(x: x, y: 0, width: 8, height: 390))
                }
            }
        // x 452 sits in a black stripe, 460 in the next white one.
        func gap(_ image: CGImage) throws -> Int {
            let data = try #require(image.dataProvider?.data as Data?)
            let bpp = image.bitsPerPixel / 8, row = image.bytesPerRow, y = 195
            return abs(Int(data[y * row + 452 * bpp]) - Int(data[y * row + 460 * bpp]))
        }
        #expect(try gap(#require(stripes.cgImage)) > 200)
        let blurred = try #require(TimerCardPhoto.blurredCopy(stripes)?.cgImage)
        #expect(try gap(blurred) < 40, "neighbouring stripes should blur together")
    }
}
