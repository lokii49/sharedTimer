//
//  WhatsNewTests.swift
//  sharedTimerTests
//

import Foundation
import Testing
@testable import sharedTimer

struct WhatsNewTests {
    @Test func versionsCompareNumerically() {
        #expect(WhatsNew.compare("1.0.10", "1.0.9") == .orderedDescending)
        #expect(WhatsNew.compare("1.0", "1.0.0") == .orderedSame)
        #expect(WhatsNew.compare("1.0.3", "1.0.4") == .orderedAscending)
        #expect(WhatsNew.compare("2", "1.9.9") == .orderedDescending)
    }

    @Test func updatingIntoTheTourShowsItOnce() {
        // 1.0.3 never stored a seen version; existing timer data marks it an update.
        #expect(WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.4", isExistingInstall: true))
        #expect(!WhatsNew.shouldShow(seenVersion: "1.0.4", currentVersion: "1.0.4", isExistingInstall: true))
        #expect(WhatsNew.shouldShow(seenVersion: "1.0.3", currentVersion: "1.0.4", isExistingInstall: true))
    }

    @Test func freshInstallNeverShows() {
        #expect(!WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.4", isExistingInstall: false))
    }

    @Test func laterVersionWithoutItsOwnTourStaysQuiet() {
        #expect(!WhatsNew.shouldShow(seenVersion: "1.0.4", currentVersion: "1.0.5", isExistingInstall: true))
        // Skipped 1.0.4 entirely (updated 1.0.3 → 1.0.5): still sees the 1.0.4 tour.
        #expect(WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.5", isExistingInstall: true))
        // An older build than the tour's version never shows it.
        #expect(!WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.3", isExistingInstall: true))
    }

    @Test func consumingMarksTheVersionSeen() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("1.0.4", forKey: WhatsNew.seenVersionKey)
        #expect(!WhatsNew.consumeLaunchPresentation(defaults: defaults))
        #expect(defaults.string(forKey: WhatsNew.seenVersionKey) == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    @Test func everyPageHasCopy() {
        #expect(WhatsNew.features.count == 6)
        #expect(WhatsNew.features.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        #expect(WhatsNew.features.map(\.id) == Array(0..<6))
    }
}
