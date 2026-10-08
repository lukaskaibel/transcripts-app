import Foundation

/// The sidebar's day plan: today's calendar meetings and recordings in one list, tomorrow's meetings, and the
/// recordings before today.
public struct Agenda: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A recording, of a calendar meeting or not.
            case recorded(MeetingRow)
            /// A calendar meeting nobody recorded.
            case planned(UpcomingMeeting)
        }

        public var kind: Kind
        public var start: Date

        public var id: String {
            switch kind {
            case .recorded(let row): "m:\(row.id)"
            case .planned(let meeting): "e:\(meeting.id)"
            }
        }

        public var planned: UpcomingMeeting? {
            if case .planned(let meeting) = kind { return meeting }
            return nil
        }
    }

    /// Today, from the morning on.
    public var today: [Item]
    /// Tomorrow's calendar meetings.
    public var tomorrow: [UpcomingMeeting]
    /// Recordings before today, newest first.
    public var recent: [MeetingRow]

    public init(rows: [MeetingRow], events: [UpcomingMeeting], now: Date = Date(), calendar: Calendar = .current, recentLimit: Int = 8) {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday) ?? now
        let todayRows = rows.filter { $0.meeting.startedAt >= startOfToday && $0.meeting.startedAt < startOfTomorrow }
        // A series has one event identifier for all its meetings: today's recording stands for today's meeting only.
        let recordedEvents = Set(todayRows.compactMap(\.meeting.calendarEventId))
        let unmatched = todayRows.filter { $0.meeting.calendarEventId == nil }.map(\.meeting.startedAt)
        let todayEvents = events.filter { event in
            event.start >= startOfToday && event.start < startOfTomorrow
                && !recordedEvents.contains(event.eventId)
                // A recording started by hand during the meeting, without the calendar knowing.
                && !unmatched.contains { $0 >= event.start.addingTimeInterval(-10 * 60) && $0 < event.end }
        }
        today = (todayRows.map { Item(kind: .recorded($0), start: $0.meeting.startedAt) }
            + todayEvents.map { Item(kind: .planned($0), start: $0.start) })
            .sorted { $0.start < $1.start }
        tomorrow = events.filter { $0.start >= startOfTomorrow && $0.start < endOfTomorrow }
        recent = Array(rows.filter { $0.meeting.startedAt < startOfToday }.prefix(recentLimit))
    }

    /// The calendar meeting to get ready for: running without a recording, or the next one today.
    public func next(now: Date = Date()) -> UpcomingMeeting? {
        today.lazy.compactMap(\.planned).first { $0.end > now }
    }

    /// How many of today's items have started by `now`: the now line goes after them.
    public func started(by now: Date = Date()) -> Int {
        today.filter { $0.start <= now }.count
    }

    /// Whether a meeting shows up in the day plan or under "Letzte Meetings".
    public func shows(meetingId: String) -> Bool {
        recent.contains { $0.id == meetingId } || today.contains { item in
            if case .recorded(let row) = item.kind { return row.id == meetingId }
            return false
        }
    }
}

extension AppModel {
    public func agenda(now: Date = Date()) -> Agenda {
        Agenda(rows: rows, events: agendaEvents, now: now)
    }
}
