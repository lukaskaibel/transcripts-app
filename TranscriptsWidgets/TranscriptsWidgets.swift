import SwiftUI
import WidgetKit

/// What Transcripts shows outside the app on iPhone and iPad: the running recording (Lock Screen, Dynamic Island) and
/// a control to start one (Control Center, Lock Screen, Action Button).
@main
struct TranscriptsWidgets: WidgetBundle {
    var body: some Widget {
        RecordingActivityWidget()
        RecordControl()
    }
}

/// Colours of the app (Theme in TranscriptsKit), for the few the extension needs.
enum WidgetTheme {
    static let recording = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let paused = Color(red: 0.96, green: 0.65, blue: 0.14)
}
