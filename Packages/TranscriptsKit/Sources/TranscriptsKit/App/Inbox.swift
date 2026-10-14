import Foundation

/// What waits for the user after their meetings: summaries they haven't read and voices without a name.
public struct Inbox: Equatable, Sendable {
    public var summaries: [MeetingRow]
    public var voices: [VoiceReview]

    public var count: Int { summaries.count + voices.count }
    public var isEmpty: Bool { count == 0 }

    /// Summaries written before `since` (when the inbox came to the app) are known already.
    public init(rows: [MeetingRow], voices: [VoiceReview], since: Date, opened: [String: Date]) {
        let fresh = rows.filter { row in
            guard row.meeting.status == .ready, let written = row.summaryCreatedAt else { return false }
            return written >= since
        }
        summaries = fresh.filter { row in (row.summaryCreatedAt ?? .distantPast) > (opened[row.id] ?? .distantPast) }
        self.voices = voices
    }
}

extension AppModel {
    public var inbox: Inbox {
        Inbox(rows: rows, voices: reviews, since: settings.inboxSince, opened: settings.openedSummaries)
    }

    /// The user has seen the meeting's summary that was written at `written`.
    public func markSummaryRead(_ meetingId: String, written: Date) {
        guard (settings.openedSummaries[meetingId] ?? .distantPast) < written else { return }
        settings.openedSummaries[meetingId] = written
    }
}
