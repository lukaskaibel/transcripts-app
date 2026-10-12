import SwiftUI
import TranscriptsKit

@main
struct TranscriptsApp: App {
    init() {
        #if os(iOS)
        RecordingLiveActivity.install()
        #endif
    }

    var body: some Scene {
        TranscriptsScene()
    }
}
