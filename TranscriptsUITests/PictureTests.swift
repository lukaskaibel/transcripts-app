import XCTest

/// The iPhone's pictures for the website, taken by Tools/iphone-images.sh in English, in light and dark. The normal
/// test runs skip them.
final class PictureTests: AppTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TR_PICTURES"] == "1", "Only for Tools/iphone-images.sh")
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone pictures")
    }

    /// Light or dark, as the script asks; the app's own setting wins over the simulator's.
    private var appearance: [String] {
        ProcessInfo.processInfo.environment["TR_APPEARANCE"].map { ["-demo.appearance", $0] } ?? []
    }

    /// The demo on its meetings. In a run of this one test, Xcode can still be installing the app when the test
    /// launches it; the system then opens the app without the test's arguments, on its own empty data and so on the
    /// onboarding. Another launch gets the arguments.
    private func launchOnTheMeetings() {
        for _ in 0..<3 {
            launch(appearance)
            if element("meeting-m-sync").waitForExistence(timeout: 6) { return }
            app.terminate()
        }
        XCTFail("The demo didn't start on the meetings")
    }

    func testPictures() {
        launchOnTheMeetings()
        element("meeting-m-sync").tap()
        wait(element("meeting.tab"))
        snapshot("iphone-meeting")

        element("voices.name").tap()
        wait(element("naming.other"))
        snapshot("iphone-naming")
        app.terminate()

        launchOnTheMeetings()
        element("record").tap()
        wait(element("live.stop"))
        // A few seconds of sound in the waveform.
        Thread.sleep(forTimeInterval: 4)
        snapshot("iphone-recording")
    }
}
