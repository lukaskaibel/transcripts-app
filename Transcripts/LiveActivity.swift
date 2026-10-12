#if os(iOS)
import ActivityKit
import AppIntents
import TranscriptsKit

/// Shows the running recording as a Live Activity: on the Lock Screen and in the Dynamic Island, with its clock and
/// buttons to pause, mark and stop.
@MainActor
enum RecordingLiveActivity {
    private static var current: Activity<RecordingActivityAttributes>?

    static func install() {
        // One left over from a run that ended without stopping (the app was quit or crashed).
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        RecordingRemote.observer = { snapshot in show(snapshot) }
    }

    private static func show(_ snapshot: RecordingSnapshot?) {
        guard let snapshot else {
            end()
            return
        }
        let state = RecordingActivityAttributes.ContentState(
            title: snapshot.title, clockStart: snapshot.clockStart, paused: snapshot.paused, elapsed: snapshot.elapsed, markers: snapshot.markers
        )
        if let current, current.attributes.meetingId == snapshot.meetingId, current.activityState == .active {
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        current = try? Activity.request(
            attributes: RecordingActivityAttributes(meetingId: snapshot.meetingId),
            content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
            pushType: nil
        )
    }

    private static func end() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

/// "Meeting aufnehmen" for Siri, Spotlight, Shortcuts and the Action Button.
struct TranscriptsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Meeting aufnehmen mit \(.applicationName)",
                "Mit \(.applicationName) aufnehmen",
                "\(.applicationName) Aufnahme starten",
            ],
            shortTitle: "Meeting aufnehmen",
            systemImageName: "waveform"
        )
    }
}
#endif
