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

    public init(eventId: String, title: String, start: Date, end: Date, attendees: [Attendee], joinURL: URL?, app: String?) {
        self.eventId = eventId
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.joinURL = joinURL
        self.app = app
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
    public func upcoming(hours: Double = 36, now: Date = Date()) -> [UpcomingMeeting] {
        guard Self.hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now }
            .compactMap(Self.meeting(from:))
            .sorted { $0.start < $1.start }
    }

    /// The meeting happening at `date`, for naming a recording that was started by hand.
    public func meeting(around date: Date) -> UpcomingMeeting? {
        guard Self.hasAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(3600), calendars: nil)
        let candidates = store.events(matching: predicate)
            .compactMap(Self.meeting(from:))
            .filter { $0.start.addingTimeInterval(-10 * 60) <= date && $0.end > date }
        // Prefer the one that started closest to now.
        return candidates.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    static func meeting(from event: EKEvent) -> UpcomingMeeting? {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        let participants = event.attendees ?? []
        if participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
        let attendees = participants
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap { participant -> Attendee? in
                let email = participant.url.absoluteString.hasPrefix("mailto:") ? String(participant.url.absoluteString.dropFirst(7)) : nil
                let name = participant.name?.trimmingCharacters(in: .whitespaces)
                guard let display = (name?.isEmpty == false ? name : email?.components(separatedBy: "@").first) else { return nil }
                return Attendee(name: display, email: email)
            }
        let link = MeetingLinks.find(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
        // Plain blocks in the calendar ("Focus", "Lunch") have neither guests nor a call link.
        guard !attendees.isEmpty || link != nil else { return nil }
        return UpcomingMeeting(
            eventId: event.eventIdentifier ?? UUID().uuidString,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            joinURL: link?.url,
            app: link?.app
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
