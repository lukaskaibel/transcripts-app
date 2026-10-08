import Foundation
import Testing
@testable import TranscriptsKit

/// The sidebar's day plan, the inbox and the way back from a meeting.
@MainActor
struct SidebarTests {
    let calendar = Calendar.current
    var today: Date { calendar.startOfDay(for: Date()) }

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!
    }

    func event(_ id: String, _ day: Int, _ hour: Int, _ minute: Int = 0, minutes: Double = 30) -> UpcomingMeeting {
        UpcomingMeeting(eventId: id, title: id, start: at(day, hour, minute), end: at(day, hour, minute).addingTimeInterval(minutes * 60),
                        attendees: [Attendee(name: "Anna")], joinURL: nil, app: nil)
    }

    func row(_ id: String, _ start: Date, event: String? = nil, summary: Date? = nil, items: [ActionItem] = []) -> MeetingRow {
        MeetingRow(meeting: Meeting(id: id, title: id, startedAt: start, duration: 1800, status: .ready, calendarEventId: event),
                   hasSummary: summary != nil, summaryCreatedAt: summary, actionItems: items)
    }

    // MARK: Day plan

    @Test func todayMixesRecordingsAndTheCalendarInOrder() {
        let rows = [row("sync", at(0, 10, 2), event: "e-sync"), row("yesterday", at(-1, 15))]
        let events = [event("e-daily", 0, 9, 15), event("e-sync", 0, 10), event("e-plan", 0, 14), event("e-hoffmann", 1, 9, 30)]
        let agenda = Agenda(rows: rows, events: events, now: at(0, 13, 12))

        #expect(agenda.today.map(\.id) == ["e:e-daily@\(Int(at(0, 9, 15).timeIntervalSince1970))", "m:sync", "e:e-plan@\(Int(at(0, 14).timeIntervalSince1970))"])
        #expect(agenda.tomorrow.map(\.eventId) == ["e-hoffmann"])
        #expect(agenda.recent.map(\.id) == ["yesterday"])
        // The now line goes after the daily and the recorded weekly; the planning is next.
        #expect(agenda.started(by: at(0, 13, 12)) == 2)
        #expect(agenda.next(now: at(0, 13, 12))?.eventId == "e-plan")
        #expect(agenda.shows(meetingId: "sync") && agenda.shows(meetingId: "yesterday") && !agenda.shows(meetingId: "other"))
    }

    @Test func todaysRecordingOfASeriesLeavesTomorrowsMeetingAlone() {
        let agenda = Agenda(rows: [row("daily", at(0, 9, 16), event: "e-daily")],
                            events: [event("e-daily", 0, 9, 15), event("e-daily", 1, 9, 15)], now: at(0, 12))
        #expect(agenda.today.map(\.id) == ["m:daily"])
        #expect(agenda.tomorrow.count == 1)
    }

    @Test func aRecordingStartedByHandStandsForTheMeetingItFallsInto() {
        let agenda = Agenda(rows: [row("by-hand", at(0, 14, 3))], events: [event("e-plan", 0, 14, minutes: 60), event("e-later", 0, 16)], now: at(0, 15))
        #expect(agenda.today.map(\.id) == ["m:by-hand", "e:e-later@\(Int(at(0, 16).timeIntervalSince1970))"])
    }

    @Test func aRunningMeetingWithoutARecordingIsNext() {
        let agenda = Agenda(rows: [], events: [event("e-now", 0, 13, minutes: 60), event("e-later", 0, 16)], now: at(0, 13, 20))
        #expect(agenda.next(now: at(0, 13, 20))?.eventId == "e-now")
        #expect(agenda.started(by: at(0, 13, 20)) == 1)
    }

    @Test func recentStopsAtItsLimit() {
        let rows = (1...12).map { row("m\($0)", at(-$0, 10)) }
        #expect(Agenda(rows: rows, events: [], now: at(0, 9), recentLimit: 8).recent.map(\.id) == (1...8).map { "m\($0)" })
    }

    // MARK: Inbox

    @Test func newSummariesAreThoseWrittenSinceTheyWereLastSeen() {
        let since = at(-2, 0)
        let rows = [
            row("old", at(-5, 10), summary: at(-5, 11)),
            row("unread", at(0, 10), summary: at(0, 11)),
            row("read", at(-1, 10), summary: at(-1, 11)),
            row("rewritten", at(-1, 14), summary: at(0, 9)),
            row("none", at(0, 8)),
        ]
        let opened = ["read": at(-1, 11), "rewritten": at(-1, 15)]
        let inbox = Inbox(rows: rows, voices: [], since: since, opened: opened, dismissed: [], githubConnected: false)
        #expect(inbox.summaries.map(\.id) == ["unread", "rewritten"])
    }

    @Test func tasksForGitHubOnlyWhenConnectedAndNotPutAside() {
        let since = at(-2, 0)
        let open = ActionItem(id: 1, meetingId: "a", text: "Fix it")
        let done = ActionItem(id: 2, meetingId: "b", text: "Done", done: true)
        let linked = ActionItem(id: 3, meetingId: "c", text: "Linked", issue: LinkedIssue(id: "I1", number: 1, url: "https://github.com/o/r/issues/1", title: "Linked", repo: "o/r", repoId: "R1"))
        let rows = [
            row("a", at(0, 10), summary: at(0, 11), items: [open]),
            row("b", at(0, 12), summary: at(0, 13), items: [done]),
            row("c", at(0, 14), summary: at(0, 15), items: [linked]),
            row("d", at(0, 16), summary: at(0, 17), items: [ActionItem(id: 4, meetingId: "d", text: "Later")]),
        ]
        let connected = Inbox(rows: rows, voices: [], since: since, opened: [:], dismissed: [Inbox.githubKey("d")], githubConnected: true)
        #expect(connected.github.map(\.id) == ["a"])
        #expect(Inbox(rows: rows, voices: [], since: since, opened: [:], dismissed: [], githubConnected: false).github.isEmpty)
    }

    @Test func readingASummaryTakesItOutOfTheInbox() throws {
        let model = try makeModel()
        let written = at(0, 11)
        model.markSummaryRead("m1", written: written)
        #expect(model.settings.openedSummaries["m1"] == written)
        // An older version doesn't count as the newest being read.
        model.markSummaryRead("m1", written: at(0, 9))
        #expect(model.settings.openedSummaries["m1"] == written)
        model.dismissGitHubTasks("m1")
        #expect(model.settings.inboxDismissed.contains(Inbox.githubKey("m1")))
    }

    @Test func theInboxStartsWhenItCameToTheApp() {
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let first = AppSettings(defaults: defaults).inboxSince
        #expect(abs(first.timeIntervalSinceNow) < 5)
        #expect(AppSettings(defaults: defaults).inboxSince == first)
    }

    @Test func meetingRowsCarryTheSummaryAndTheTasks() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Meeting(id: "m1", title: "Weekly", status: .ready))
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        try database.save(summary: MeetingSummary(meetingId: "m1", overview: "Release moves.", decisions: [], openQuestions: [], model: "m", provider: "p", createdAt: written),
                          actionItems: [ActionItem(meetingId: "m1", text: "One"), ActionItem(meetingId: "m1", text: "Two", position: 1)])
        let row = try #require(try database.meetingRows().first)
        #expect(row.summaryCreatedAt == written)
        #expect(row.summaryOverview == "Release moves.")
        #expect(row.actionItems.map(\.text) == ["One", "Two"])
        #expect(row.unsentTasks == 2)
    }

    // MARK: Navigation

    @Test func aMeetingOpenedFromTheInboxLeadsBackThere() throws {
        let model = try makeModel()
        model.show(.inbox)
        model.select("m1")
        #expect(model.section == .meetings && model.backSection == .inbox)
        model.goBack()
        #expect(model.section == .inbox && model.selectedMeetingId == nil && model.backSection == nil)

        // From the list, back is the list.
        model.select(nil)
        model.select("m1")
        #expect(model.backSection == nil)
        model.goBack()
        #expect(model.section == .meetings && model.selectedMeetingId == nil)
    }

    func makeModel() throws -> AppModel {
        AppModel(database: try AppDatabase.inMemory(), settings: AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!),
                 secrets: MemorySecretStore(), isDemo: true)
    }
}
