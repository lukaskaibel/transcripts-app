#if os(iOS)
import AppIntents
#if TRANSCRIPTS_APP
import TranscriptsKit
#endif

// The recording, controlled from outside the app. Compiled into the app, where they run (`TRANSCRIPTS_APP`), and into
// the widget extension, whose buttons name them.

/// Pause and resume, from the Live Activity.
struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme pausieren oder fortsetzen"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if TRANSCRIPTS_APP
        await RecordingRemote.togglePause()
        #endif
        return .result()
    }
}

/// Mark this moment, from the Live Activity.
struct MarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Moment markieren"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if TRANSCRIPTS_APP
        await RecordingRemote.addMarker()
        #endif
        return .result()
    }
}

/// End the recording, from the Live Activity; the meeting is then transcribed in full.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Aufnahme beenden"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if TRANSCRIPTS_APP
        await RecordingRemote.stop()
        #endif
        return .result()
    }
}

/// Start recording a meeting without opening the app: from Control Center, the Action Button, Siri or Shortcuts.
/// The recording shows as a Live Activity right away, as the system wants it of an audio recording started this way.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Meeting aufnehmen"
    static let description = IntentDescription("Startet eine Aufnahme in Transcripts. Läuft schon eine, läuft sie weiter.")

    func perform() async throws -> some IntentResult {
        #if TRANSCRIPTS_APP
        await RecordingRemote.start()
        #endif
        return .result()
    }
}
#endif
