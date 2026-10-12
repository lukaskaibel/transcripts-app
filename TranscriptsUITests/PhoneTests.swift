import XCTest

/// Every screen of the iPhone app, on the made-up meetings of the demo mode.
final class PhoneTests: AppTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone layout")
    }

    // MARK: Meetings

    func testMeetingsShowTheDayPlanAndEveryMeeting() {
        launch()
        wait(app.navigationBars["Meetings"])
        wait(element("meeting-m-sync"))
        XCTAssertTrue(element("meeting-m-sync").label.contains("Weekly Produkt-Sync"), element("meeting-m-sync").label)
        XCTAssertTrue(element("meeting-m-sync").label.contains("2 Stimmen offen"), element("meeting-m-sync").label)
        wait(element("planned-e-daily"))
        wait(element("record"))
        snapshot("Meetings")

        element("agenda.tomorrow").tap()
        wait(element("planned-e-hoffmann"))
        snapshot("Meetings, tomorrow unfolded")
    }

    func testAMeetingShowsSummaryVoicesAndTranscript() {
        launch()
        element("meeting-m-sync").tap()
        wait(labelled("Zusammenfassung"))
        wait(button("Wer ist das?"))
        snapshot("Meeting")
        app.swipeUp(velocity: .slow)
        snapshot("Meeting, tasks")
        app.swipeUp(velocity: .slow)
        snapshot("Meeting, speakers")
        app.swipeUp(velocity: .fast)
        snapshot("Meeting, transcript")
        element("meeting.more").tap()
        wait(button("Umbenennen …"))
        snapshot("Meeting, menu")
    }

    func testAPlannedMeetingOffersToRecordIt() {
        launch()
        element("agenda.tomorrow").tap()
        element("planned-e-hoffmann").tap()
        wait(button("Aufnehmen"))
        snapshot("Upcoming meeting")
    }

    func testTasksGoToGitHubFromTheMeeting() {
        launch()
        element("meeting-m-sync").tap()
        let open = element("github.open")
        scrollTo(open)
        open.tap()
        wait(element("github.composer"), 10)
        wait(element("github.create"))
        snapshot("GitHub composer")
        element("github.target").tap()
        wait(element("picker.search"))
        snapshot("GitHub target picker")
    }

    func testAMeetingCanBeRenamed() {
        launch()
        element("meeting-m-sync").tap()
        element("meeting.more").tap()
        button("Umbenennen …").tap()
        let alert = app.alerts.firstMatch
        wait(alert)
        // The field has the keyboard, with the cursor after the title.
        let field = alert.textFields.firstMatch
        wait(field)
        field.typeText(" 2")
        alert.buttons["Sichern"].tap()
        waitGone(alert)
        wait(labelled("Weekly Produkt-Sync 2"))
    }

    func testAVoiceGetsANameFromTheSpeakers() {
        launch()
        element("meeting-m-sync").tap()
        let speaker = labelled("Jonas Weber?", type: .button)
        scrollTo(speaker)
        speaker.tap()
        wait(button("Jonas Weber"))
        snapshot("Speaker menu")
        button("Jonas Weber").tap()
    }

    func testATaskCanBeCheckedOff() {
        launch(["-mobile.tab", "tasks"])
        let box = app.buttons.matching(NSPredicate(format: "label == %@", "Als erledigt markieren")).firstMatch
        wait(box)
        box.tap()
        wait(app.buttons.matching(NSPredicate(format: "label == %@", "Als offen markieren")).firstMatch)
        snapshot("Task checked off")
    }

    // MARK: Recording

    func testRecordingRunsBehindTheTabsAndStops() {
        launch()
        element("record").tap()
        wait(element("live.stop"))
        wait(labelled("Sprint Planning 43"))
        snapshot("Recording")
        element("live.mark").tap()
        element("live.pause").tap()
        waitForLabel(element("live.pause"), containing: "Fortsetzen")
        snapshot("Recording, paused")
        element("live.summary").tap()
        wait(labelled("Live-Zusammenfassung"))
        snapshot("Recording, live summary")
        app.swipeDown(velocity: .fast)
        element("live.close").tap()
        wait(element("live.open"))
        snapshot("Recording behind the tabs")
        element("live.open").tap()
        wait(element("live.stop"))
        element("live.stop").tap()
        wait(element("record"))
        snapshot("Recording stopped")
    }

    // MARK: Inbox, tasks, people

    func testInboxListsSummariesTasksAndVoices() {
        launch(["-mobile.tab", "inbox"])
        wait(app.navigationBars["Eingang"])
        wait(element("inbox.summary.m-sync"))
        snapshot("Inbox")
        element("inbox.nameAll").tap()
        wait(labelled("Wer ist das?"))
        snapshot("Who is this")
    }

    func testTasksCanBeCheckedOff() {
        launch(["-mobile.tab", "tasks"])
        wait(app.navigationBars["Aufgaben"])
        snapshot("Tasks")
        element("tasks.onlyMine").tap()
        snapshot("Tasks, only mine")
    }

    func testPeopleShowVoicesAndAPerson() {
        launch(["-mobile.tab", "people"])
        wait(app.navigationBars["Personen"])
        wait(element("people.nameAll"))
        snapshot("People")
        scrollTo(element("people.moreVoices"))
        wait(element("people.moreVoices"))
        scrollTo(element("person-p-anna"))
        snapshot("People, known")
        element("person-p-anna").tap()
        wait(element("person.name"))
        snapshot("Person")
    }

    func testSearchFindsMeetingsAndLines() {
        launch(["-mobile.tab", "search"])
        let field = app.searchFields.firstMatch
        wait(field)
        snapshot("Search")
        field.tap()
        field.typeText("Release")
        wait(labelled("Im Transkript"))
        snapshot("Search, results")
    }

    func testSettingsHaveEveryPage() {
        launch()
        element("settings").tap()
        wait(element("settings.general"))
        snapshot("Settings")
        for page in ["general", "recording", "transcription", "ai", "voices", "github"] {
            element("settings.\(page)").tap()
            Thread.sleep(forTimeInterval: 0.6)
            snapshot("Settings, \(page)")
            goBack()
        }
        element("settings.done").tap()
    }

    func testOnboarding() {
        launch(["-demo.onboarding", "YES"])
        wait(element("onboarding.name"))
        snapshot("Onboarding")
    }
}
