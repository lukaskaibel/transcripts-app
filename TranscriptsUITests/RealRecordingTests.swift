import XCTest

/// A real recording on the simulator: the demo plays a file as the microphone (`-demo.recordFrom`), so the live
/// transcript, the speech recognition and the processing afterwards run as on a phone, without anyone's microphone.
/// It needs the speech models in the app (copied into its Application Support/FluidAudio) and TR_RECORD_FILE, a
/// 16 kHz recording of a German meeting (Tools/make-test-meeting.py makes one); normal test runs skip it.
final class RealRecordingTests: AppTestCase {
    private var file: String? { ProcessInfo.processInfo.environment["TR_RECORD_FILE"] }

    override func setUpWithError() throws {
        try XCTSkipIf(file == nil, "Needs TR_RECORD_FILE and the speech models in the app")
        try XCTSkipIf(isPad, "iPhone only")
    }

    func testARealRecordingIsTranscribedLiveAndAfterwards() throws {
        let file = try XCTUnwrap(file)
        launch(["-demo.recordFrom", file])
        element("record").tap()
        wait(element("live.stop"))

        // The first words of the made-up meeting, while it is still playing.
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Themen")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 45), "No live transcript")
        snapshot("Real recording, live")
        Thread.sleep(forTimeInterval: 20)
        snapshot("Real recording, later")

        // Behind the tabs, the bar above the tab bar keeps the time.
        element("live.close").tap()
        wait(element("live.open"))
        Thread.sleep(forTimeInterval: 10)
        snapshot("Real recording behind the tabs")
        element("live.open").tap()
        wait(element("live.stop"))
        // The rest of the file.
        Thread.sleep(forTimeInterval: 50)
        snapshot("Real recording, end")
        element("live.stop").tap()

        // The meeting opens while it is processed, its lines not yet anyone's.
        wait(element("meeting.processing"), 20)
        snapshot("Real recording, processing")
        button("Transkript").tap()
        snapshot("Real recording, processing, transcript")
        waitGone(element("meeting.processing"), 400)
        snapshot("Real recording, processed, transcript")
        button("Zusammenfassung").tap()
        snapshot("Real recording, processed")
    }
}
