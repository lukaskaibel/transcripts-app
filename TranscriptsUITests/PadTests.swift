import XCTest

/// The iPad's own layout: the sidebar, lists with the meeting beside them, the inspector, and the live window.
final class PadTests: AppTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout")
    }

    override func setUp() {
        super.setUp()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testMeetingsListWithTheMeetingBeside() {
        launch()
        wait(element("record"))
        wait(element("meeting-m-sync"))
        snapshot("iPad, meetings")
        element("meeting-m-sync").tap()
        wait(labelled("Zusammenfassung"))
        wait(labelled("Sprecher"))
        snapshot("iPad, meeting with inspector")
    }

    func testInboxWithTheMeetingBeside() {
        launch(["-mobile.tab", "inbox"])
        wait(element("inbox.summary.m-sync"))
        element("inbox.summary.m-sync").tap()
        wait(labelled("Zusammenfassung"))
        snapshot("iPad, inbox")
    }

    func testPeopleWithThePersonBeside() {
        launch(["-mobile.tab", "people"])
        scrollTo(element("person-p-anna"))
        element("person-p-anna").tap()
        wait(element("person.name"))
        snapshot("iPad, people")
    }

    func testTheLiveWindowShowsTheSummaryBeside() {
        launch()
        element("record").tap()
        wait(element("live.stop"))
        wait(labelled("Live-Zusammenfassung"))
        snapshot("iPad, recording")
        element("live.close").tap()
        wait(element("live.open"))
        snapshot("iPad, recording in the sidebar")
        element("record.stop").tap()
        wait(element("record"))
    }

    func testPortraitShowsTheSameScreens() {
        XCUIDevice.shared.orientation = .portrait
        launch()
        wait(element("meeting-m-sync"))
        snapshot("iPad portrait, meetings")
        element("meeting-m-sync").tap()
        wait(labelled("Zusammenfassung"))
        snapshot("iPad portrait, meeting")
    }

    func testSettings() {
        launch()
        element("settings").tap()
        wait(element("settings.general"))
        element("settings.general").tap()
        snapshot("iPad, settings")
    }
}
