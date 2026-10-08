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
        upcoming = calendar.upcoming(filter: meetingFilter)
        let today = Calendar.current.startOfDay(for: Date())
        agendaEvents = calendar.meetings(from: today, to: Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today, filter: meetingFilter)
        Task { await rescheduleReminders() }
    }

    /// The user's meetings: by the rule in the settings, without the ones they hid.
    var meetingFilter: MeetingFilter {
        let hidden = settings.hiddenMeetings
        return MeetingFilter(onlyMine: settings.onlyMyMeetings,
                             hiddenEvents: Set(hidden.filter { $0.kind == .event }.map(\.identifier)),
                             hiddenCalendars: Set(hidden.filter { $0.kind == .calendar }.map(\.identifier)))
    }

    // MARK: Not my meeting

    /// "Nicht mein Meeting": the series (or the whole calendar) no longer shows up and no longer reminds.
    public func hide(_ item: HiddenCalendarItem) {
        settings.hiddenMeetings.removeAll { $0.id == item.id }
        settings.hiddenMeetings.append(item)
        if isDemo {
            upcoming.removeAll { !meetingFilter.allows($0) }
            agendaEvents.removeAll { !meetingFilter.allows($0) }
        } else {
            refreshCalendar()
        }
        let title = switch item.kind {
        case .event: item.isRecurring
            ? String(localized: "Serie „\(item.title)“ ausgeblendet", comment: "toast: a recurring calendar meeting no longer shows up")
            : String(localized: "„\(item.title)“ ausgeblendet", comment: "toast: a calendar meeting no longer shows up")
        case .calendar: String(localized: "Kalender „\(item.title)“ ausgeblendet", comment: "toast: the meetings of a calendar no longer show up")
        }
        showToast(title, String(localized: "Auch keine Erinnerungen mehr. Zurückholen: Einstellungen › Allgemein."), action: .unhide(item))
    }

    public func unhide(_ item: HiddenCalendarItem) {
        settings.hiddenMeetings.removeAll { $0.id == item.id }
        if isDemo {
            upcoming = DemoData.upcoming().filter(meetingFilter.allows)
            agendaEvents = DemoData.agenda().filter(meetingFilter.allows)
        } else {
            refreshCalendar()
        }
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
        case .notMine(let eventId, let title):
            hide(upcoming.first { $0.eventId == eventId }.map(HiddenCalendarItem.meeting) ?? HiddenCalendarItem(kind: .event, identifier: eventId, title: title))
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
