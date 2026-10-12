import AppIntents
import SwiftUI
import WidgetKit

/// "Meeting aufnehmen" in Control Center, on the Lock Screen and on the Action Button.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.lukaskbl.Transcripts.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label(String(localized: "Meeting aufnehmen"), systemImage: "waveform")
            }
        }
        .displayName("Meeting aufnehmen")
        .description("Startet eine Aufnahme in Transcripts.")
    }
}
