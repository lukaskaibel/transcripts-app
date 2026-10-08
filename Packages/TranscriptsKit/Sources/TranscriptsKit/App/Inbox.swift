import Foundation

/// What waits for the user after their meetings: summaries they haven't read, tasks not yet on GitHub, voices
/// without a name.
public struct Inbox: Equatable, Sendable {
    public var summaries: [MeetingRow]
    public var github: [MeetingRow]
    public var voices: [VoiceReview]

    public var count: Int { summaries.count + github.count + voices.count }
    public var isEmpty: Bool { count == 0 }

    /// Summaries written before `since` (when the inbox came to the app) are known already.
    public init(rows: [MeetingRow], voices: [VoiceReview], since: Date, opened: [String: Date], dismissed: Set<String>, githubConnected: Bool) {
        let fresh = rows.filter { row in
            guard row.meeting.status == .ready, let written = row.summaryCreatedAt else { return false }
            return written >= since
        }
        summaries = fresh.filter { row in (row.summaryCreatedAt ?? .distantPast) > (opened[row.id] ?? .distantPast) }
        github = githubConnected ? fresh.filter { $0.unsentTasks > 0 && !dismissed.contains(Self.githubKey($0.id)) } : []
        self.voices = voices
    }

    static func githubKey(_ meetingId: String) -> String { "github:\(meetingId)" }
}

extension AppModel {
    public var inbox: Inbox {
        Inbox(rows: rows, voices: reviews, since: settings.inboxSince, opened: settings.openedSummaries,
              dismissed: settings.inboxDismissed, githubConnected: settings.githubLogin != nil)
    }

    /// The user has seen the meeting's summary that was written at `written`.
    public func markSummaryRead(_ meetingId: String, written: Date) {
        guard (settings.openedSummaries[meetingId] ?? .distantPast) < written else { return }
        settings.openedSummaries[meetingId] = written
    }

    /// "Ignorieren": the meeting's tasks stay off GitHub, and the inbox stops asking.
    public func dismissGitHubTasks(_ meetingId: String) {
        settings.inboxDismissed.insert(Inbox.githubKey(meetingId))
    }
}
