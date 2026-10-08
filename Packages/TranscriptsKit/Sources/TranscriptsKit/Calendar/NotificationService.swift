import Foundation
import UserNotifications

/// What the user tapped in one of the app's notifications.
public enum NotificationAction: Equatable, Sendable {
    /// Start recording; carries the calendar event when the reminder came from one.
    case record(eventId: String?, start: Date?)
    case snooze(eventId: String, title: String, start: Date)
    /// "Nicht mein Meeting" on a reminder: hide the series.
    case notMine(eventId: String, title: String)
    case stopRecording
    case open
    /// "Anlegen" on the tasks of a summary: create them where they were prepared to go.
    case createIssues(meetingId: String)
    /// A click on that notification: show the tasks in the composer.
    case reviewIssues(meetingId: String)
}

/// Reminders when a calendar meeting starts, and the "meeting detected" and "call ended" prompts.
@MainActor
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    nonisolated static let meetingCategory = "MEETING_START"
    nonisolated static let detectedCategory = "MEETING_DETECTED"
    nonisolated static let endedCategory = "MEETING_ENDED"
    nonisolated static let issuesCategory = "GITHUB_ISSUES"
    nonisolated static let createIssuesAction = "CREATE_ISSUES"
    nonisolated static let reviewIssuesAction = "REVIEW_ISSUES"
    nonisolated static let recordAction = "RECORD"
    nonisolated static let laterAction = "LATER"
    nonisolated static let ignoreAction = "IGNORE"
    nonisolated static let notMineAction = "NOT_MINE"
    nonisolated static let stopAction = "STOP"
    nonisolated static let reminderPrefix = "reminder-"

    public var onAction: ((NotificationAction) -> Void)?
    private var center: UNUserNotificationCenter? {
        // Unit tests run without an app bundle, where the notification center is unavailable.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Registers the actions. Call once at launch, before any notification can be answered.
    public func activate() {
        guard let center else { return }
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: String(localized: "Aufnehmen", comment: "notification button: start recording"), options: [])
        let later = UNNotificationAction(identifier: Self.laterAction, title: String(localized: "Später", comment: "notification button: remind me later"), options: [])
        let notMine = UNNotificationAction(identifier: Self.notMineAction, title: String(localized: "Nicht mein Meeting", comment: "notification button: this calendar meeting isn't the user's, don't remind again"), options: [])
        let ignore = UNNotificationAction(identifier: Self.ignoreAction, title: String(localized: "Ignorieren", comment: "notification button: ignore the detected meeting"), options: [.destructive])
        let stop = UNNotificationAction(identifier: Self.stopAction, title: String(localized: "Aufnahme beenden"), options: [])
        let create = UNNotificationAction(identifier: Self.createIssuesAction, title: String(localized: "Anlegen", comment: "notification button: create the prepared GitHub issues"), options: [])
        let review = UNNotificationAction(identifier: Self.reviewIssuesAction, title: String(localized: "Vorher ansehen", comment: "notification button: look at the GitHub issues before creating them"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory, actions: [record, later, notMine], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.detectedCategory, actions: [record, ignore], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.endedCategory, actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.issuesCategory, actions: [create, review], intentIdentifiers: []),
        ])
    }

    public func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    /// Whether the notifications stay on screen until clicked (the style "Dauerhaft", "Persistent") instead of sliding away.
    public func usesPersistentAlerts() async -> Bool {
        guard let center else { return false }
        return await center.notificationSettings().alertStyle == .alert
    }

    /// Replaces the scheduled reminders with one per upcoming meeting, `lead` seconds before it starts.
    public func scheduleReminders(for meetings: [UpcomingMeeting], lead: TimeInterval, recordingEventId: String?) async {
        guard let center else { return }
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let now = Date()
        for meeting in meetings where meeting.eventId != recordingEventId {
            let fireAt = meeting.start.addingTimeInterval(-lead)
            guard fireAt > now.addingTimeInterval(5), fireAt < now.addingTimeInterval(36 * 3600) else { continue }
            let content = UNMutableNotificationContent()
            content.title = lead >= 60 ? String(localized: "\(meeting.title) beginnt gleich") : String(localized: "\(meeting.title) beginnt")
            content.body = meeting.subtitle.isEmpty ? String(localized: "Aufnahme starten?") : "\(meeting.subtitle)\n\(String(localized: "Aufnahme starten?"))"
            content.categoryIdentifier = Self.meetingCategory
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["eventId": meeting.eventId, "start": meeting.start.timeIntervalSince1970, "title": meeting.title]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSince(now), repeats: false)
            let request = UNNotificationRequest(identifier: Self.reminderPrefix + meeting.id, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    public func snooze(eventId: String, title: String, start: Date, minutes: Double = 5) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(title) läuft", comment: "notification title: the meeting has started and is still going on")
        content.body = String(localized: "Aufnahme jetzt starten?")
        content.categoryIdentifier = Self.meetingCategory
        content.sound = .default
        content.userInfo = ["eventId": eventId, "start": start.timeIntervalSince1970, "title": title]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: minutes * 60, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "snooze-\(eventId)", content: content, trigger: trigger))
    }

    public func notifyCallDetected(appName: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Meeting erkannt")
        content.body = String(localized: "\(appName) nutzt gerade das Mikrofon. Aufnehmen?")
        content.categoryIdentifier = Self.detectedCategory
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        try? await center.add(UNNotificationRequest(identifier: "detected-\(UUID().uuidString)", content: content, trigger: nil))
    }

    public func notifyCallEnded(appName: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Call beendet?")
        content.body = String(localized: "\(appName) nutzt das Mikrofon nicht mehr, die Aufnahme läuft aber noch.")
        content.categoryIdentifier = Self.endedCategory
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "ended-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// The tasks of a summary are ready for their remembered place on GitHub.
    public func notifyIssuesReady(meetingId: String, title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.issuesCategory
        content.userInfo = ["meetingId": meetingId]
        try? await center.add(UNNotificationRequest(identifier: "issues-\(meetingId)", content: content, trigger: nil))
    }

    public func notify(title: String, body: String) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let eventId = info["eventId"] as? String
        let title = info["title"] as? String ?? String(localized: "Meeting", comment: "title of a calendar event that has none")
        let start = (info["start"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let action: NotificationAction?
        switch response.actionIdentifier {
        case Self.recordAction:
            action = .record(eventId: eventId, start: start)
        case Self.laterAction:
            action = eventId.map { .snooze(eventId: $0, title: title, start: start ?? Date()) }
        case Self.notMineAction:
            action = eventId.map { .notMine(eventId: $0, title: title) }
        case Self.stopAction:
            action = .stopRecording
        case Self.createIssuesAction:
            action = (info["meetingId"] as? String).map { .createIssues(meetingId: $0) }
        case Self.reviewIssuesAction:
            action = (info["meetingId"] as? String).map { .reviewIssues(meetingId: $0) }
        case Self.ignoreAction, UNNotificationDismissActionIdentifier:
            action = nil
        default:
            // A click on the notification itself: a reminder or detection means "record", anything else opens the app.
            if category == Self.meetingCategory || category == Self.detectedCategory {
                action = .record(eventId: eventId, start: start)
            } else if category == Self.endedCategory {
                action = .open
            } else if category == Self.issuesCategory, let meetingId = info["meetingId"] as? String {
                action = .reviewIssues(meetingId: meetingId)
            } else {
                action = .open
            }
        }
        guard let action else { return }
        await MainActor.run { self.onAction?(action) }
    }
}
