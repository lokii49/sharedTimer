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
        // A pre-1.0.4 install never stored a seen version; existing timer data marks it an update.
        #expect(WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.10", isExistingInstall: true))
        #expect(!WhatsNew.shouldShow(seenVersion: "1.0.10", currentVersion: "1.0.10", isExistingInstall: true))
        // Saw the 1.0.9 tour: the 1.0.10 one is new (numeric compare, not "1.0.10" < "1.0.9").
        #expect(WhatsNew.shouldShow(seenVersion: "1.0.9", currentVersion: "1.0.10", isExistingInstall: true))
        #expect(WhatsNew.shouldShow(seenVersion: "1.0.7", currentVersion: "1.0.10", isExistingInstall: true))
    }

    @Test func freshInstallNeverShows() {
        #expect(!WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.10", isExistingInstall: false))
    }

    @Test func laterVersionWithoutItsOwnTourStaysQuiet() {
        #expect(!WhatsNew.shouldShow(seenVersion: "1.0.10", currentVersion: "1.0.11", isExistingInstall: true))
        // Skipped 1.0.10 entirely (updated 1.0.9 → 1.0.11): still sees the 1.0.10 tour.
        #expect(WhatsNew.shouldShow(seenVersion: "1.0.9", currentVersion: "1.0.11", isExistingInstall: true))
        // An older build than the tour's version never shows it (1.0.9 with this tour's code).
        #expect(!WhatsNew.shouldShow(seenVersion: nil, currentVersion: "1.0.9", isExistingInstall: true))
    }

    @Test func consumingMarksTheVersionSeen() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(WhatsNew.contentVersion, forKey: WhatsNew.seenVersionKey)
        #expect(!WhatsNew.consumeLaunchPresentation(defaults: defaults))
        #expect(defaults.string(forKey: WhatsNew.seenVersionKey) == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    @Test func everyPageHasCopy() {
        #expect(WhatsNew.features.count == 4)
        #expect(WhatsNew.features.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        #expect(WhatsNew.features.map(\.id) == Array(0..<4))
    }
}
