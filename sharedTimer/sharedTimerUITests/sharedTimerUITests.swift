//
//  sharedTimerUITests.swift
//  sharedTimerUITests
//
//  Created by Lokesh Pudhari on 09/08/26.
//

import XCTest

final class sharedTimerUITests: XCTestCase {
    private var widgetTestURL: URL?


    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        if let url = widgetTestURL {
            let app = XCUIApplication()
            app.open(url)
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 3) { delete.tap() }
            app.terminate()
        }
        widgetTestURL = nil
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testShareLinkPresentsSystemShareSheet() throws {
        // The system share sheet must show up on top of ShareTimerSheet.
        let app = XCUIApplication()
        let id = UUID().uuidString
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: "Share Sheet Test"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "0")
        ]
        let link = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = link
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        let row = app.staticTexts["Share Sheet Test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)
        let shareButton = app.buttons["Share…"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10))
        shareButton.tap()
        // First share asks for a display name unless one is already stored.
        let skipName = app.alerts.buttons["Skip"]
        if skipName.waitForExistence(timeout: 3) { skipName.tap() }
        let shareLink = app.buttons["Share Link"]
        XCTAssertTrue(shareLink.waitForExistence(timeout: 10))
        shareLink.tap()
        let copy = app.staticTexts["Copy"]
        // Apple's share sheet can take a while to fill in; 10s failed now and then.
        XCTAssertTrue(copy.waitForExistence(timeout: 30))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "System share sheet over ShareTimerSheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        copy.tap()
        XCTAssertTrue(shareLink.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    @MainActor
    func testRightToLeftLayoutScreenshots() throws {
        // Visual check for the Arabic (RTL) localization: list, Settings, a timer's detail.
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
        let id = UUID().uuidString
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: "RTL"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "0")
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.launch()
        app.open(try XCTUnwrap(share.url))
        sleep(3)
        attachScreenshot(app, "RTL add sheet")
        let add = app.buttons["إضافة إلى مؤقتاتي"]  // "Add to My Timers" in Arabic
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        sleep(2)
        attachScreenshot(app, "RTL list")
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        sleep(2)
        attachScreenshot(app, "RTL Settings")
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tapping a list card opens its detail on iPhone (the iPad split view's tap
    /// selection must not take the tap from the row's NavigationLink).
    @MainActor
    func testTappingACardOpensItsDetail() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let label = "Tap UI \(id.prefix(4))"
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "3600"), URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    @MainActor
    func testFinishedTimerAppearsInHistoryWithRunAgain() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let label = "History UI \(id.prefix(4))"
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(-30).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "120"), URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        let history = app.buttons["historyButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Run again"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "History"
        shot.lifetime = .keepAlways
        add(shot)
        // N4: Stats opens from History, shows the run's name and offers Export.
        let stats = app.buttons["statsButton"]
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        stats.tap()
        // Section titles are drawn upper-case (skyLabel).
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'By name'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[label].exists)
        XCTAssertTrue(app.buttons["exportButton"].exists)
        let statsShot = XCTAttachment(screenshot: app.screenshot())
        statsShot.name = "Stats"
        statsShot.lifetime = .keepAlways
        add(statsShot)
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to History
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 5))
        // Don't leave the fixture in the device's real History.
        app.staticTexts[label].firstMatch.swipeLeft()
        // (The label itself stays visible in the timer list behind the sheet.)
        let forget = app.buttons["Forget"].firstMatch
        XCTAssertTrue(forget.waitForExistence(timeout: 3))
        forget.tap()
        app.buttons["Done"].tap()
    }

    @MainActor
    func testSettingsPicksAToneAndShowsAbout() throws {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Settings (Sky Stack)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Put back whichever tone the phone had (Settings re-arms every alarm with it).
        let original = ["Classic", "Glass", "Ember", "Dawn"].first { app.buttons[$0].isSelected } ?? "Classic"
        let other = original == "Glass" ? "Ember" : "Glass"
        let pick = app.buttons[other]
        XCTAssertTrue(pick.exists)
        pick.tap()
        XCTAssertTrue(pick.isSelected)
        app.buttons[original].tap()
        XCTAssertTrue(app.buttons[original].isSelected)
        XCTAssertTrue(app.staticTexts["Privacy Policy"].exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testDetailShareButtonOpensShareSheet() throws {
        // The display-name prompt and share sheet used to hang off the list root, so they
        // never appeared while the detail screen was pushed.
        let app = XCUIApplication()
        let id = UUID().uuidString
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: "Detail Share Test"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "0")
        ]
        let link = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = link
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(link)
        let shareButton = app.buttons["Share"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10))
        shareButton.tap()
        let skipName = app.alerts.buttons["Skip"]
        if skipName.waitForExistence(timeout: 3) { skipName.tap() }
        XCTAssertTrue(app.buttons["Share Link"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
    }

    /// A friend's link opened while a detail screen is pushed must still offer the timer:
    /// the Add sheet hung off the list root inside the NavigationStack and never appeared
    /// there (1.0.9 moved it outside the stack, like the share sheet).
    @MainActor
    func testIncomingLinkOffersTheTimerWhileADetailScreenIsOpen() throws {
        let app = XCUIApplication()
        func shareURL(_ id: String, _ label: String) throws -> URL {
            var share = URLComponents(string: "https://mirrornotes.org/timer")!
            share.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "label", value: label),
                URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)),
                URLQueryItem(name: "dur", value: "300"),
                URLQueryItem(name: "kind", value: "timer"),
                URLQueryItem(name: "alarm", value: "0"),
                URLQueryItem(name: "vib", value: "0")
            ]
            return try XCTUnwrap(share.url)
        }
        let id = UUID().uuidString
        let link = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = link
        app.open(try shareURL(id, "Pushed Detail Test"))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(link)
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 10))  // the detail screen is up
        app.open(try shareURL(UUID().uuidString, "Second Link Test"))
        XCTAssertTrue(app.buttons["Add to My Timers"].waitForExistence(timeout: 10), "the offer must appear over the detail screen")
        app.buttons["Not Now"].firstMatch.tap()
    }

    /// iPad: the detail column sits beside the list and keeps its own copy. A Pause from
    /// the list's swipe must reach it — before 1.0.8 the column kept showing the timer
    /// running, and its +1:00 saved that running copy back, silently un-pausing it.
    @MainActor
    func testIPadDetailFollowsAListPauseAndKeepsItOnExtend() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad split view only") }
        let app = XCUIApplication()
        let id = UUID().uuidString
        let label = "iPad Sync \(id.prefix(4))"
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(3600).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "3600"), URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
        ]
        let link = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = link
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(link)  // selects it: the detail column shows this timer
        XCTAssertTrue(app.buttons["+1:00"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pause"].exists)

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.swipeRight()
        let swipePause = app.collectionViews.buttons["Pause"].firstMatch
        XCTAssertTrue(swipePause.waitForExistence(timeout: 5))
        swipePause.tap()

        // The detail column follows the list…
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        // …and its +1:00 extends the paused timer instead of un-pausing it.
        app.buttons["+1:00"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause"].exists)
    }

    @MainActor
    func testWidgetLinkOpensStoredTimerAndDoesNotRecreateAfterDeletion() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let label = "Widget Link Test"
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "0")
        ]
        let link = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = link
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(link)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[label].firstMatch.exists)
        XCTAssertTrue(app.buttons["+1:00"].exists)
        XCTAssertFalse(app.buttons["Add to My Timers"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Widget link opens current timer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        delete.tap()
        widgetTestURL = nil
        app.open(link)
        XCTAssertTrue(app.staticTexts["Timer unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Add to My Timers"].exists)
    }

    /// N1: the voice button turns spoken cues on (and keeps the screen awake) for a
    /// running sequence, and off again.
    @MainActor
    func testVoiceCuesTurnOnWithTheScreenAwake() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let phases: [[String: Any]] = [
            ["label": "Voice Work", "kind": "timer", "duration": 300, "alarmEnabled": false, "vibrationEnabled": false],
            ["label": "Voice Rest", "kind": "timer", "duration": 60, "alarmEnabled": false, "vibrationEnabled": false]
        ]
        let envelope: [String: Any] = ["version": 1, "sequence": ["phases": phases, "loopCount": 2, "phaseIndex": 0, "loopIndex": 0]]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: "Voice Work"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(300).timeIntervalSince1970)), URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"), URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0"),
            URLQueryItem(name: "seq", value: String(data: json, encoding: .utf8))
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(try XCTUnwrap(widgetTestURL))
        let voice = app.buttons["voiceCueButton"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        XCTAssertEqual(voice.value as? String, "Off")
        voice.tap()
        XCTAssertEqual(voice.value as? String, "On")
        // The voice keeps the screen on.
        XCTAssertEqual(app.buttons["Keep Screen On"].value as? String, "On")
        sleep(3)   // a few ticks with the voice on
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Voice on"
        shot.lifetime = .keepAlways
        add(shot)
        voice.tap()   // off again, so the pattern isn't left talking
        XCTAssertEqual(voice.value as? String, "Off")
    }

    @MainActor
    func testSharedScheduledSequenceCanStartPauseAndResume() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let label = "Shared Sequence UI"
        let phases: [[String: Any]] = [
            ["label": label, "kind": "timer", "duration": 300, "alarmEnabled": false, "vibrationEnabled": false],
            ["label": "Rest", "kind": "timer", "duration": 60, "alarmEnabled": false, "vibrationEnabled": false]
        ]
        let envelope: [String: Any] = ["version": 1, "sequence": ["phases": phases, "loopCount": 2, "phaseIndex": 0, "loopIndex": 0]]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        let start = Date().addingTimeInterval(3600).timeIntervalSince1970
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "end", value: String(start + 300)), URLQueryItem(name: "dur", value: "300"),
            URLQueryItem(name: "kind", value: "timer"), URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0"),
            URLQueryItem(name: "seq", value: String(data: json, encoding: .utf8)), URLQueryItem(name: "start", value: String(start))
        ]
        let detail = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = detail
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Shared sequence from a link"].exists)
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(detail)
        XCTAssertTrue(app.buttons["Start Now"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        app.buttons["Start Now"].tap()
        XCTAssertTrue(app.staticTexts["Phase 1 of 2 · Loop 1 of 2"].waitForExistence(timeout: 5))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["+1:00"].tap()
        XCTAssertTrue(app.buttons["Resume"].exists)
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Shared sequence recipient controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Delete"].tap()
        widgetTestURL = nil
    }

    @MainActor
    /// N3: the round "−" beside +1:00 takes a minute off (the end time moves back).
    func testRemoveMinuteShortensATimer() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: "Remove minute test"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(600).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "600"), URLQueryItem(name: "kind", value: "timer"),
            URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(try XCTUnwrap(widgetTestURL))
        let minus = app.buttons["-1:00"]
        XCTAssertTrue(minus.waitForExistence(timeout: 10))
        let endsBefore = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ends at'")).firstMatch.label
        minus.tap()
        let endsAfter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ends at'")).firstMatch
        XCTAssertTrue(endsAfter.waitForExistence(timeout: 5))
        XCTAssertNotEqual(endsAfter.label, endsBefore, "the end time moves back a minute")
    }

    /// N5: tag a timer and give it a note from its screen, filter the list by the tag
    /// (the other timer drops out and is counted), then clear the filter. Cleans up the
    /// second timer and the tag itself; teardown deletes the first.
    @MainActor
    func testTagFilterAndNote() throws {
        let app = XCUIApplication()
        func importTimer(_ label: String) throws -> String {
            let id = UUID().uuidString
            var share = URLComponents(string: "https://mirrornotes.org/timer")!
            share.queryItems = [
                URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: label),
                URLQueryItem(name: "end", value: String(Date().addingTimeInterval(900).timeIntervalSince1970)),
                URLQueryItem(name: "dur", value: "900"), URLQueryItem(name: "kind", value: "timer"),
                URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
            ]
            app.open(try XCTUnwrap(share.url))
            let add = app.buttons["Add to My Timers"]
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
            if app.alerts.buttons["Not Now"].waitForExistence(timeout: 2) { app.alerts.buttons["Not Now"].tap() }
            return id
        }
        let tagged = try importTimer("Tag test A")
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + tagged))
        let other = try importTimer("Tag test B")
        let tagName = "UITag\(Int(Date().timeIntervalSince1970) % 100_000)"

        // On the timer's screen: a new tag, then a note.
        app.open(try XCTUnwrap(widgetTestURL))
        let tagsMenu = app.buttons["tagsMenu"]
        XCTAssertTrue(tagsMenu.waitForExistence(timeout: 10))
        tagsMenu.tap()
        let newTag = app.buttons["New Tag…"].firstMatch
        XCTAssertTrue(newTag.waitForExistence(timeout: 5))
        newTag.waitForHittable(timeout: 3)
        newTag.tap()
        let nameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText(tagName)
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", tagName)).firstMatch.waitForExistence(timeout: 5))
        app.buttons["addNoteButton"].tap()
        let editor = app.textViews["noteEditor"].exists ? app.textViews["noteEditor"] : app.textFields["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("Turn at half time")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["noteBox"].waitForExistence(timeout: 5))
        let detailShot = XCTAttachment(screenshot: app.screenshot()); detailShot.name = "Tags detail"; detailShot.lifetime = .keepAlways; add(detailShot)

        // The list, filtered by the tag: A shows, B is counted under "other tags".
        // iPhone: back to the list. iPad: the list is already beside the detail.
        let chip = app.scrollViews["tagFilterBar"].buttons[tagName]
        if !chip.waitForExistence(timeout: 2) { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let otherRow = app.buttons["otherTagsRow"]
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Tag test B'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Tag test A'")).firstMatch.exists)
        let listShot = XCTAttachment(screenshot: app.screenshot()); listShot.name = "Tags list filtered"; listShot.lifetime = .keepAlways; add(listShot)
        otherRow.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Tag test B'")).firstMatch.waitForExistence(timeout: 5))

        // Clean up: the tag, then the second timer.
        app.scrollViews["tagFilterBar"].buttons[tagName].press(forDuration: 1.0)
        app.buttons["Delete Tag"].firstMatch.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete Tag'")).firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        app.open(try XCTUnwrap(URL(string: "sharedtimer://timer/" + other)))
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 5) { delete.tap() }
    }

    /// N6 / N7: make a days-since count (shows "Today", Start Over, delete) and run the
    /// stopwatch (start, lap, pause, reset). Screenshots for review; cleans up after.
    @MainActor
    func testDaysSinceAndStopwatch() throws {
        let app = XCUIApplication()
        app.launch()
        func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
        let plus = app.buttons["New"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        let name = "Since test \(Int(Date().timeIntervalSince1970) % 100_000)"

        plus.tap()
        app.buttons["Days Since…"].tap()
        let label = app.textFields["daysSinceLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap(); label.typeText(name)
        app.buttons["daysSinceStart"].tap()
        let card = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue((card.value as? String ?? "").hasPrefix(String(localized: "Today")))
        shot("Since in list")
        card.tap()
        let startOver = app.buttons["daysSinceStartOver"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 5))
        shot("Since detail")
        app.buttons["Delete"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).element(boundBy: 1)
        if confirm.waitForExistence(timeout: 3) { confirm.tap() } else { app.sheets.buttons["Delete"].firstMatch.tap() }
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))

        plus.tap()
        app.buttons["Stopwatch"].tap()
        let startPause = app.buttons["stopwatchStartPause"]
        XCTAssertTrue(startPause.waitForExistence(timeout: 5))
        startPause.tap()
        sleep(2)
        app.buttons["stopwatchLap"].tap()
        sleep(1)
        app.buttons["stopwatchLap"].tap()
        sleep(1)
        startPause.tap()
        shot("Stopwatch paused with laps")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Lap 2'")).firstMatch.exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["stopwatchRow"].waitForExistence(timeout: 5) || app.otherElements["stopwatchRow"].exists)
        shot("Stopwatch in list")
        app.buttons["stopwatchRow"].firstMatch.tap()
        let reset = app.buttons["stopwatchReset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        app.buttons["Close"].tap()
    }

    /// N13: a timer with a bright photo (seeded — the system picker can't be driven):
    /// its card and its screen keep white text readable. Screenshots for review.
    @MainActor
    func testPhotoBackgroundScreens() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        let id = UUID().uuidString
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: "Photo test"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(86_400 * 29).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: String(86_400 * 30)), URLQueryItem(name: "kind", value: "countdown"),
            URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0")
        ]
        widgetTestURL = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        app.open(try XCTUnwrap(share.url))
        let add = app.buttons["Add to My Timers"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        if app.alerts.buttons["Not Now"].waitForExistence(timeout: 2) { app.alerts.buttons["Not Now"].tap() }
        app.terminate()
        app.launchArguments = ["-SeedPhoto", id]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo test'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Photo card"; list.lifetime = .keepAlways; self.add(list)
        app.open(try XCTUnwrap(widgetTestURL))
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 10))
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "Photo detail"; detail.lifetime = .keepAlways; self.add(detail)
        #endif
    }

    /// History redesign + Stats, on realistic seeded runs (simulator only — the seed
    /// doesn't exist in device builds): screenshots of each screen for review.
    @MainActor
    func testHistoryAndStatsScreens() throws {
        #if targetEnvironment(simulator)
        let app = XCUIApplication()
        app.launchArguments += ["-SeedHistory"] + (ProcessInfo.processInfo.environment["HISTORY_SHOT_ARGS"]?.components(separatedBy: " ") ?? [])
        app.launch()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let history = app.buttons["historyButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pomodoro'")).firstMatch.waitForExistence(timeout: 5))
        shot("History")
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pomodoro'")).firstMatch.tap()
        sleep(1)
        shot("History group")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["statsButton"].tap()
        XCTAssertTrue(app.buttons["exportButton"].waitForExistence(timeout: 5))
        shot("Stats week")
        // By position, so the test runs in any language.
        app.segmentedControls.buttons.element(boundBy: 1).tap(); sleep(1); shot("Stats month")
        app.segmentedControls.buttons.element(boundBy: 2).tap(); sleep(1); shot("Stats all")
        #endif
    }

    @MainActor
    func testWhatsNewTourPagesThroughToStart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ShowWhatsNew"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tags and notes"].waitForExistence(timeout: 10))
        sleep(4)  // the tags scene filters and shows the note
        let firstPage = XCTAttachment(screenshot: app.screenshot())
        firstPage.name = "What's New page 1"
        firstPage.lifetime = .keepAlways
        add(firstPage)
        let continueButton = app.buttons["Continue"]
        for (index, title) in ["Stats", "Test my alarm", "More in Messages", "Days since and a stopwatch"].enumerated() {
            continueButton.tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
            sleep(2)  // let the page's scene play to a telling frame
            let page = XCTAttachment(screenshot: app.screenshot())
            page.name = "What's New page \(index + 2)"
            page.lifetime = .keepAlways
            add(page)
        }
        let lastPage = XCTAttachment(screenshot: app.screenshot())
        lastPage.name = "What's New last page"
        lastPage.lifetime = .keepAlways
        add(lastPage)
        app.buttons["Start"].tap()
        XCTAssertTrue(app.navigationBars["Timers"].waitForExistence(timeout: 5) || app.buttons["New"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alarms that listen"].exists)
    }

    @MainActor
    func testEditRenamesCountdownInPlace() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "label", value: "Edit Me UI"),
            URLQueryItem(name: "end", value: String(Date().addingTimeInterval(86_400).timeIntervalSince1970)),
            URLQueryItem(name: "dur", value: "86400"),
            URLQueryItem(name: "kind", value: "countdown"),
            URLQueryItem(name: "alarm", value: "0"),
            URLQueryItem(name: "vib", value: "0")
        ]
        let detail = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = detail
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(detail)

        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        let field = app.textFields["Label"]
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Edited UI")
        XCTAssertTrue(save.isEnabled)
        save.tap()

        XCTAssertTrue(app.staticTexts["Edited UI"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Edit Me UI"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Countdown after Edit"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Delete"].tap()
        widgetTestURL = nil
    }

    /// A shared yearly countdown (the tallest detail screen: Next Year row, Repeats
    /// yearly line) at the largest text size must still offer a reachable Delete.
    @MainActor
    func testDetailDeleteStaysReachableAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let id = UUID().uuidString
        let target = Date().addingTimeInterval(3600)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: target)
        let envelope: [String: Any] = ["version": 1, "recurrence": ["month": parts.month!, "day": parts.day!,
            "hour": parts.hour!, "minute": parts.minute!, "second": parts.second!, "timeZoneID": "GMT"]]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        var share = URLComponents(string: "https://mirrornotes.org/timer")!
        share.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: "Large Text Delete"),
            URLQueryItem(name: "end", value: String(target.timeIntervalSince1970)), URLQueryItem(name: "dur", value: "3600"),
            URLQueryItem(name: "kind", value: "countdown"), URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0"),
            URLQueryItem(name: "annual", value: String(data: json, encoding: .utf8))]
        let detail = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = detail
        app.open(try XCTUnwrap(share.url))
        let addButton = app.buttons["Add to My Timers"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(detail)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Detail at largest text size"
        attachment.lifetime = .keepAlways
        add(attachment)
        if !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable, "Delete is off-screen at the largest text size")
        delete.tap()
        widgetTestURL = nil
    }

    @MainActor
    func testYearlyCountdownImportCanSkipPauseResumeAndDelete() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        let target = Date().addingTimeInterval(3600)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: target)
        let envelope: [String: Any] = ["version": 1, "recurrence": ["month": parts.month!, "day": parts.day!,
            "hour": parts.hour!, "minute": parts.minute!, "second": parts.second!, "timeZoneID": "GMT"]]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        var share = URLComponents(string: "https://lokii49.github.io/sharedTimer/t.html")!
        share.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "label", value: "Yearly Countdown UI"),
            URLQueryItem(name: "end", value: String(target.timeIntervalSince1970)), URLQueryItem(name: "dur", value: "3600"),
            URLQueryItem(name: "kind", value: "countdown"), URLQueryItem(name: "alarm", value: "0"), URLQueryItem(name: "vib", value: "0"),
            URLQueryItem(name: "annual", value: String(data: json, encoding: .utf8))]
        let detail = try XCTUnwrap(URL(string: "sharedtimer://timer/" + id))
        widgetTestURL = detail
        app.open(try XCTUnwrap(share.url))
        XCTAssertTrue(app.staticTexts["Shared yearly countdown from a link"].waitForExistence(timeout: 10))
        app.buttons["Add to My Timers"].tap()
        if app.alerts.buttons["Not Now"].exists { app.alerts.buttons["Not Now"].tap() }
        app.open(detail)
        XCTAssertTrue(app.staticTexts["Repeats yearly · GMT"].waitForExistence(timeout: 10))
        app.buttons["Next Year"].tap()
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.dateFormat = "yyyy-MM-dd"
        let next = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: target))
        XCTAssertTrue(app.staticTexts[formatter.string(from: next)].waitForExistence(timeout: 10))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        app.buttons["+1:00"].tap()
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Yearly countdown after Next Year"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Delete"].tap()
        widgetTestURL = nil
    }

    @MainActor
    func testNewCountdownOffersCalendarImportAndYearlyRepeat() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["New"].tap()
        app.buttons["New Countdown"].tap()
        // D8 · A: a Repeat menu (Never / Daily / Weekly / Monthly / Yearly).
        let repeatMenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch
        XCTAssertTrue(repeatMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import from Calendar"].exists)
        repeatMenu.tap()
        let weekly = app.buttons["Weekly"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        weekly.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Every ")).firstMatch.waitForExistence(timeout: 5))
        repeatMenu.tap()
        let yearly = app.buttons["Yearly"]
        XCTAssertTrue(yearly.waitForExistence(timeout: 5))
        yearly.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "February 29 uses February 28")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "New countdown yearly and Calendar options"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testCalendarImportLoadsEventsWithFullAccess() throws {
        let monitor = addUIInterruptionMonitor(withDescription: "Calendar full access") { alert in
            guard alert.label.localizedCaseInsensitiveContains("calendar") else { return false }
            let allow = alert.buttons.allElementsBoundByIndex.first {
                $0.label.localizedCaseInsensitiveContains("allow") && !$0.label.localizedCaseInsensitiveContains("don't")
            }
            guard let allow else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let app = XCUIApplication()
        app.launch()
        app.buttons["New"].tap()
        app.buttons["New Countdown"].tap()
        let importButton = app.buttons["Import from Calendar"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // firstMatch: the permission alert sometimes exposes the button twice
        // ("Multiple matching elements"), which failed this test intermittently.
        let allow = system.buttons["Allow Full Access"].firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.navigationBars["Import from Calendar"].waitForExistence(timeout: 10))
        let loading = app.staticTexts["Loading events…"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
        if app.staticTexts["Allow Calendar access in Settings to choose an event. You can also enter a date yourself."].exists {
            app.buttons["Open Settings"].tap()
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            let permission = settings.cells.containing(.staticText, identifier: "Calendars").firstMatch
            XCTAssertTrue(permission.waitForExistence(timeout: 10))
            permission.tap()
            let full = settings.staticTexts["Full Access"]
            XCTAssertTrue(full.waitForExistence(timeout: 5))
            full.tap()
            let confirmation = system.alerts.firstMatch
            if confirmation.waitForExistence(timeout: 3) {
                let grant = confirmation.buttons.allElementsBoundByIndex.first {
                    $0.label.localizedCaseInsensitiveContains("allow") && !$0.label.localizedCaseInsensitiveContains("don't")
                }
                try XCTUnwrap(grant).tap()
            }
            app.activate()
            let retry = app.buttons["Try Again"]
            if retry.exists { retry.tap() }
            let retryLoaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: loading)
            XCTAssertEqual(XCTWaiter.wait(for: [retryLoaded], timeout: 15), .completed)
        }
        XCTAssertFalse(app.staticTexts["Allow Calendar access in Settings to choose an event. You can also enter a date yourself."].exists)
        XCTAssertFalse(app.staticTexts["Calendar events couldn’t be loaded. Try again or enter a date yourself."].exists)
        XCTAssertTrue(app.staticTexts["Choose an event in the next year. Its title and start time become your countdown; Calendar stays unchanged."].exists)
        app.navigationBars["Import from Calendar"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}

private extension XCUIElement {
    @discardableResult
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if exists && isHittable { return true }; usleep(100_000) }
        return exists && isHittable
    }
}
