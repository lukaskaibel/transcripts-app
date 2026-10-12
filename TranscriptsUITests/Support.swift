import XCTest

/// Shared steps for the UI tests of the iPhone and iPad app. Every test starts the app fresh on the made-up meetings
/// of the demo mode, so tests never record, never touch the user's data, and never depend on each other.
class AppTestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Starts on the Meetings tab unless the test asks for another with `-mobile.tab`.
    @discardableResult
    func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let tab = arguments.contains("-mobile.tab") ? [] : ["-mobile.tab", "meetings"]
        // In German, the language the texts are written in, whatever the simulator's language: the tests find some
        // buttons by their labels. TR_LANGUAGE (TEST_RUNNER_TR_LANGUAGE for xcodebuild) runs them in another, to look
        // at a translation.
        app.launchArguments = ["-demo", "YES", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            + tab + arguments
        app.launch()
        self.app = app
        return app
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var language: String { ProcessInfo.processInfo.environment["TR_LANGUAGE"] ?? "de" }

    var locale: String { ProcessInfo.processInfo.environment["TR_LOCALE"] ?? (language == "en" ? "en_US" : "de_DE") }

    /// Any element with this accessibility identifier.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The first element whose label contains the text.
    func labelled(_ text: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func button(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    /// A tab of the tab bar (or the iPad's sidebar), by its title.
    func tab(_ title: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[title].firstMatch
        return inBar.exists ? inBar : app.buttons[title].firstMatch
    }

    func wait(_ element: XCUIElement, _ timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing: \(element)", file: file, line: line)
    }

    func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
        let gone = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: gone, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "Still there: \(element)", file: file, line: line)
    }

    func waitForLabel(_ element: XCUIElement, containing text: String, _ timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "\(element.label) lacks \(text)", file: file, line: line)
    }

    /// Scrolls until the element is on screen and clear of the tab bar and the record bar, which lists scroll under.
    func scrollTo(_ element: XCUIElement, in container: XCUIElement? = nil, maxSwipes: Int = 10) {
        var swipes = 0
        while !(element.exists && element.isHittable && !behindBars(element)) && swipes < maxSwipes {
            (container ?? app).swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    private func behindBars(_ element: XCUIElement) -> Bool {
        let bar = app.tabBars.firstMatch
        // The record bar sits about 60 points above the tab bar.
        return bar.exists && bar.frame.height > 0 && element.frame.maxY > bar.frame.minY - 70
    }

    /// Back one screen.
    func goBack() {
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["BackButton"]
        if back.exists {
            back.tap()
        } else {
            bar.buttons.element(boundBy: 0).tap()
        }
    }

    /// Keeps a screenshot with the test results, to look at afterwards.
    func snapshot(_ name: String) {
        // Let springs and fades settle first.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
