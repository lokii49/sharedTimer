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
    func testWhatsNewTourPagesThroughToStart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ShowWhatsNew"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Pause from the Lock Screen"].waitForExistence(timeout: 10))
        let firstPage = XCTAttachment(screenshot: app.screenshot())
        firstPage.name = "What's New page 1"
        firstPage.lifetime = .keepAlways
        add(firstPage)
        let continueButton = app.buttons["Continue"]
        for title in ["Edit any timer", "Countdowns that come back every year", "Share a whole sequence",
                      "Start your usual timer in one tap", "Siri, Spotlight and your Watch"] {
            continueButton.tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
        }
        let lastPage = XCTAttachment(screenshot: app.screenshot())
        lastPage.name = "What's New last page"
        lastPage.lifetime = .keepAlways
        add(lastPage)
        app.buttons["Start"].tap()
        XCTAssertTrue(app.navigationBars["Timers"].waitForExistence(timeout: 5) || app.buttons["New"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Siri, Spotlight and your Watch"].exists)
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
        let toggle = app.switches["Repeat yearly"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import from Calendar"].exists)
        let control = toggle.switches.firstMatch
        if control.exists { control.tap() } else { toggle.tap() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
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
        let allow = system.buttons["Allow Full Access"]
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
        XCTAssertTrue(app.switches["Repeat yearly"].waitForExistence(timeout: 5))
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
