#if os(iOS)
import ActivityKit
import Foundation

/// The running recording on the Lock Screen and in the Dynamic Island. Compiled into the app, which starts and updates
/// it, and into the widget extension, which draws it.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        /// When the clock would have started had it never paused: a running clock counts up from here.
        var clockStart: Date
        var paused: Bool
        /// Seconds recorded, for the clock standing still while paused.
        var elapsed: Double
        var markers: Int
    }

    var meetingId: String
}
#endif
