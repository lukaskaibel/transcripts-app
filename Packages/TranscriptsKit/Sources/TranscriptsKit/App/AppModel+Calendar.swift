import AppKit
import Foundation

extension AppModel {
    /// Loads upcoming meetings and keeps them (and the reminders) current.
    func startCalendar() {
        guard !isDemo else { return }
        refreshCalendar()
        calendar.observeChanges { [weak self] in self?.refreshCalendar() }
        calendarTimerStart()
    }

    private func calendarTimerStart() {
        guard calendarTimerTask == nil else { return }
        calendarTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refreshCalendar()
            }
        }
    }

    public func refreshCalendar() {
        guard !isDemo else { return }
        upcoming = calendar.upcoming()
        Task { await rescheduleReminders() }
    }

    func rescheduleReminders() async {
        guard !isDemo else { return }
        guard settings.calendarReminders, CalendarService.hasAccess else {
            await notifications.scheduleReminders(for: [], lead: 0, recordingEventId: nil)
            return
        }
        let recordingEvent = recording.flatMap { session in rows.first { $0.id == session.meetingId }?.meeting.calendarEventId }
        await notifications.scheduleReminders(for: upcoming, lead: settings.reminderLead, recordingEventId: recordingEvent)
    }

    /// The next meeting worth showing in the sidebar and the menu bar: running now or starting within 12 hours.
    public var nextMeetings: [UpcomingMeeting] {
        let now = Date()
        return upcoming.filter { $0.end > now && $0.start < now.addingTimeInterval(36 * 3600) }
    }

    /// A meeting that starts within 15 minutes or is running, for the record button in the menu bar.
    public var imminentMeeting: UpcomingMeeting? {
        let now = Date()
        return upcoming.first { $0.start <= now.addingTimeInterval(15 * 60) && $0.end > now }
    }

    // MARK: Call detection

    public func configureCallDetection() {
        guard !isDemo else { return }
        if settings.detectCalls {
            detector.onCallStarted = { [weak self] call in self?.callStarted(call) }
            detector.onCallEnded = { [weak self] call in self?.callEnded(call) }
            detector.start()
        } else {
            detector.stop()
        }
    }

    private func callStarted(_ call: DetectedCall) {
        guard recording == nil, settings.detectCalls else { return }
        // A calendar reminder for this call already asked.
        if let imminent = imminentMeeting, abs(imminent.start.timeIntervalSinceNow) < 10 * 60, settings.calendarReminders { return }
        Task { await notifications.notifyCallDetected(appName: call.appName) }
    }

    private func callEnded(_ call: DetectedCall) {
        guard recording != nil else { return }
        Task { await notifications.notifyCallEnded(appName: call.appName) }
    }

    // MARK: Notification actions

    func handle(_ action: NotificationAction) {
        switch action {
        case .record(let eventId, _):
            let event = eventId.flatMap { id in upcoming.first { $0.eventId == id } }
            Task { await startRecording(event: event) }
        case .snooze(let eventId, let title, let start):
            Task { await notifications.snooze(eventId: eventId, title: title, start: start) }
        case .stopRecording:
            Task { await stopRecording() }
        case .open:
            openMainWindow()
        case .createIssues(let meetingId):
            Task { await createPreparedIssues(meetingId) }
        case .reviewIssues(let meetingId):
            requestComposer(for: meetingId)
        }
    }
}
