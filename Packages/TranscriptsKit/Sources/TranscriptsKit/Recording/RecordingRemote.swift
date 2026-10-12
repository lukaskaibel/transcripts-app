import Foundation
import Observation

/// The running recording as the system shows it outside the app: the Live Activity on the Lock Screen and in the
/// Dynamic Island.
public struct RecordingSnapshot: Equatable, Sendable {
    public var meetingId: String
    public var title: String
    /// When the clock would have started had it never paused: a running clock counts up from here.
    public var clockStart: Date
    public var paused: Bool
    /// Seconds recorded, for the clock standing still while paused.
    public var elapsed: TimeInterval
    public var markers: Int
}

/// The recording, controlled from outside the app: the buttons of the Live Activity, Control Center, the Action
/// Button and Shortcuts. The app target (which has the Live Activity) registers `observer`; the model registers itself.
@MainActor
public enum RecordingRemote {
    /// Called whenever the recording starts, pauses, resumes, gets a marker or a new title, and with nil when it ends.
    public static var observer: ((RecordingSnapshot?) -> Void)? {
        didSet { model?.publishRecording() }
    }

    static weak var model: AppModel?

    public static var snapshot: RecordingSnapshot? { model?.recordingSnapshot }

    /// Starts a recording (or, when one runs, leaves it running).
    public static func start() async {
        guard let model, model.recording == nil else { return }
        await model.startRecording()
    }

    public static func stop() async {
        await model?.stopRecording()
    }

    public static func togglePause() {
        model?.togglePause()
    }

    /// Marks this moment, as the button on the recording screen does.
    public static func addMarker() {
        model?.recording?.addMarker("")
    }
}

extension AppModel {
    var recordingSnapshot: RecordingSnapshot? {
        guard let session = recording, session.state == .recording || session.state == .paused else { return nil }
        let elapsed = session.recordedTime
        return RecordingSnapshot(
            meetingId: session.meetingId,
            title: session.title,
            clockStart: Date().addingTimeInterval(-elapsed),
            paused: session.state == .paused,
            elapsed: elapsed,
            markers: session.markers.count
        )
    }

    /// Tells the observer when the recording changes in a way it shows: not every second, the clock runs by itself.
    func observeRecordingForRemote() {
        RecordingRemote.model = self
        withObservationTracking {
            _ = recording?.state
            _ = recording?.title
            _ = recording?.markers.count
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publishRecording()
                self?.observeRecordingForRemote()
            }
        }
    }

    func publishRecording() {
        RecordingRemote.observer?(recordingSnapshot)
    }
}

extension RecordingSession {
    /// Seconds recorded so far, pauses left out; also for the demo's recording, whose clock doesn't run.
    var recordedTime: TimeInterval { max(clock.elapsed, elapsed) }
}
