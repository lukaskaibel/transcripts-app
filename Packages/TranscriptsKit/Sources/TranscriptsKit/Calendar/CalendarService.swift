import AppKit
import EventKit
import Foundation

/// A calendar event that looks like a meeting worth recording.
public struct UpcomingMeeting: Identifiable, Hashable, Sendable {
    public var id: String { "\(eventId)@\(Int(start.timeIntervalSince1970))" }
    public var eventId: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Invitees without the user.
    public var attendees: [Attendee]
    public var joinURL: URL?
    /// "Zoom", "Microsoft Teams", "Google Meet" … when the event carries a link to one.
    public var app: String?
    public var calendarId: String?
    /// The calendar's name, like "Arbeit" or a calendar shared by a team.
    public var calendarTitle: String?
    /// The calendar's color as red, green, blue (0…1).
    public var calendarColor: [Double]?
    /// One of a series: hiding it hides every occurrence.
    public var isRecurring: Bool

    public init(eventId: String, title: String, start: Date, end: Date, attendees: [Attendee], joinURL: URL?, app: String?,
                calendarId: String? = nil, calendarTitle: String? = nil, calendarColor: [Double]? = nil, isRecurring: Bool = false) {
        self.eventId = eventId
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.joinURL = joinURL
        self.app = app
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor
        self.isRecurring = isRecurring
    }

    public var isRunning: Bool { start <= Date() && end > Date() }

    /// "Zoom · Anna, Thomas, Jonas +1".
    public var subtitle: String {
        var parts: [String] = []
        if let app { parts.append(app) }
        if !attendees.isEmpty {
            let names = attendees.prefix(3).map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name }
            parts.append(names.joined(separator: ", ") + (attendees.count > 3 ? " +\(attendees.count - 3)" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// Which calendar events count as the user's meetings.
public struct MeetingFilter: Sendable {
    /// Leave out events with guests the user is neither among nor organizing (a colleague's or a team's shared calendar).
    public var onlyMine: Bool
    public var hiddenEvents: Set<String>
    public var hiddenCalendars: Set<String>

    public init(onlyMine: Bool = true, hiddenEvents: Set<String> = [], hiddenCalendars: Set<String> = []) {
        self.onlyMine = onlyMine
        self.hiddenEvents = hiddenEvents
        self.hiddenCalendars = hiddenCalendars
    }

    public func allows(_ meeting: UpcomingMeeting) -> Bool {
        !hiddenEvents.contains(meeting.eventId) && !(meeting.calendarId.map(hiddenCalendars.contains) ?? false)
    }
}

/// A meeting series or a whole calendar the user said isn't theirs: no row in "Anstehend", no reminder.
public struct HiddenCalendarItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case event, calendar }
    public var kind: Kind
    /// The event's or the calendar's identifier.
    public var identifier: String
    /// The meeting's or the calendar's name, for the list in the settings.
    public var title: String
    /// For a meeting: its calendar.
    public var calendarTitle: String?
    public var isRecurring: Bool

    public var id: String { "\(kind.rawValue):\(identifier)" }

    public init(kind: Kind, identifier: String, title: String, calendarTitle: String? = nil, isRecurring: Bool = false) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.calendarTitle = calendarTitle
        self.isRecurring = isRecurring
    }

    public static func meeting(_ meeting: UpcomingMeeting) -> HiddenCalendarItem {
        HiddenCalendarItem(kind: .event, identifier: meeting.eventId, title: meeting.title, calendarTitle: meeting.calendarTitle, isRecurring: meeting.isRecurring)
    }

    public static func calendar(of meeting: UpcomingMeeting) -> HiddenCalendarItem? {
        guard let id = meeting.calendarId else { return nil }
        return HiddenCalendarItem(kind: .calendar, identifier: id, title: meeting.calendarTitle ?? String(localized: "Kalender"))
    }
}

/// A guest or the organizer of an event, as far as it matters for whose meeting it is.
struct EventPerson: Equatable {
    var email: String?
    var isCurrentUser: Bool
    /// Rooms and equipment are guests too, but say nothing about who takes part.
    var isPerson = true

    /// Whether the user takes part: invited or organizing. Without guests nothing says otherwise.
    static func includesUser(attendees: [EventPerson], organizer: EventPerson?, ownAddresses: Set<String>) -> Bool {
        let people = attendees.filter(\.isPerson)
        guard !people.isEmpty else { return true }
        return (people + [organizer].compactMap { $0 }).contains { person in
            person.isCurrentUser || person.email.map { ownAddresses.contains($0.lowercased()) } ?? false
        }
    }
}

/// Reads the calendars the user already has on this Mac (iCloud, Google, Exchange …).
@MainActor
public final class CalendarService {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    public init() {}

    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public static var wasAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Calls `handler` whenever events change, also when changed on another device.
    public func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Meetings starting within `hours` (or running right now), soonest first.
    public func upcoming(hours: Double = 36, now: Date = Date(), filter: MeetingFilter = MeetingFilter()) -> [UpcomingMeeting] {
        guard Self.hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return Self.meetings(from: store.events(matching: predicate).filter { $0.endDate > now }, filter: filter)
            .sorted { $0.start < $1.start }
    }

    /// The meeting happening at `date`, for naming a recording that was started by hand.
    public func meeting(around date: Date, filter: MeetingFilter = MeetingFilter()) -> UpcomingMeeting? {
        guard Self.hasAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(3600), calendars: nil)
        let candidates = Self.meetings(from: store.events(matching: predicate), filter: filter)
            .filter { $0.start.addingTimeInterval(-10 * 60) <= date && $0.end > date }
        // Prefer the one that started closest to now.
        return candidates.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    /// Every event of the coming hours with its guests and whether it counts, for checking the rules on a real calendar.
    func report(hours: Double = 36, now: Date = Date(), filter: MeetingFilter) -> [String] {
        guard Self.hasAccess else { return ["no calendar access"] }
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(hours * 3600), calendars: nil))
            .filter { $0.endDate > now }
        let shown = Set(Self.meetings(from: events, filter: filter).map(\.id))
        func describe(_ participant: EKParticipant) -> String {
            "\(Self.email(of: participant) ?? participant.url.absoluteString)\(participant.isCurrentUser ? "*" : "")"
        }
        return events.sorted { $0.startDate < $1.startDate }.map { event in
            let id = "\(event.eventIdentifier ?? "")@\(Int(event.startDate.timeIntervalSince1970))"
            return "\(shown.contains(id) ? "SHOW" : "hide") \(event.title ?? "-") | \(event.calendar?.title ?? "-") | organizer=\(event.organizer.map(describe) ?? "-") | guests=\((event.attendees ?? []).map(describe)) | link=\(MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })?.app ?? "-")"
        }
    }

    static func meetings(from events: [EKEvent], filter: MeetingFilter) -> [UpcomingMeeting] {
        // The user's addresses, from the events they are in: an invitation to one of them counts in every calendar.
        let ownAddresses = Set(events.flatMap { ($0.attendees ?? []) + [$0.organizer].compactMap { $0 } }
            .filter(\.isCurrentUser).compactMap { Self.email(of: $0)?.lowercased() })
        var seen = Set<String>()
        return events.compactMap { event in
            guard let meeting = meeting(from: event, onlyMine: filter.onlyMine, ownAddresses: ownAddresses), filter.allows(meeting) else { return nil }
            // A meeting in the user's calendar and in a shared one is there twice.
            let key = "\(event.calendarItemExternalIdentifier ?? meeting.title)@\(Int(meeting.start.timeIntervalSince1970))"
            return seen.insert(key).inserted ? meeting : nil
        }
    }

    private static func email(of participant: EKParticipant) -> String? {
        participant.url.absoluteString.hasPrefix("mailto:") ? String(participant.url.absoluteString.dropFirst(7)) : nil
    }

    private static func person(_ participant: EKParticipant) -> EventPerson {
        EventPerson(email: email(of: participant), isCurrentUser: participant.isCurrentUser,
                    isPerson: participant.participantType != .room && participant.participantType != .resource)
    }

    static func meeting(from event: EKEvent, onlyMine: Bool = true, ownAddresses: Set<String> = []) -> UpcomingMeeting? {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        let participants = event.attendees ?? []
        if participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
        if onlyMine, !EventPerson.includesUser(attendees: participants.map(person), organizer: event.organizer.map(person), ownAddresses: ownAddresses) { return nil }
        let attendees = participants
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap { participant -> Attendee? in
                let email = email(of: participant)
                let name = participant.name?.trimmingCharacters(in: .whitespaces)
                guard let display = (name?.isEmpty == false ? name : email?.components(separatedBy: "@").first) else { return nil }
                return Attendee(name: display, email: email)
            }
        let link = MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
        // Plain blocks in the calendar ("Focus", "Lunch") have neither guests nor a call link.
        guard !attendees.isEmpty || link != nil else { return nil }
        return UpcomingMeeting(
            eventId: event.eventIdentifier ?? UUID().uuidString,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(localized: "Meeting", comment: "title of a calendar event that has none"),
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            joinURL: link?.url,
            app: link?.app,
            calendarId: event.calendar?.calendarIdentifier,
            calendarTitle: event.calendar?.title,
            calendarColor: event.calendar?.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map(Double.init) },
            isRecurring: event.hasRecurrenceRules || event.isDetached
        )
    }
}

/// Finds video call links in event fields.
public enum MeetingLinks {
    static let services: [(pattern: String, app: String)] = [
        (#"https?://[\w.-]*zoom\.us/(j|my|w|s)/[^\s<>"]+"#, "Zoom"),
        (#"https?://teams\.(microsoft|live)\.com/[^\s<>"]+"#, "Microsoft Teams"),
        (#"https?://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}[^\s<>"]*"#, "Google Meet"),
        (#"https?://[\w.-]*webex\.com/[^\s<>"]+"#, "Webex"),
        (#"https?://[\w.-]*whereby\.com/[^\s<>"]+"#, "Whereby"),
        (#"https?://meet\.jit\.si/[^\s<>"]+"#, "Jitsi"),
        (#"https?://[\w.-]*slack\.com/huddle/[^\s<>"]+"#, "Slack"),
        (#"https?://(app\.)?chime\.aws/[^\s<>"]+"#, "Amazon Chime"),
        (#"https?://[\w.-]*gotomeeting\.com/[^\s<>"]+"#, "GoTo Meeting"),
    ]

    public static func find(in texts: [String]) -> (url: URL, app: String)? {
        for text in texts {
            for service in services {
                if let range = text.range(of: service.pattern, options: [.regularExpression, .caseInsensitive]),
                   let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ">).,;"))) {
                    return (url, service.app)
                }
            }
        }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
