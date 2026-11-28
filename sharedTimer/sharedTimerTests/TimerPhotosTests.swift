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
        let saved = TimerPhotos.directory
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
        TimerPhotos.directory = dir
        defer { TimerPhotos.directory = saved; try? FileManager.default.removeItem(at: dir) }
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
}
