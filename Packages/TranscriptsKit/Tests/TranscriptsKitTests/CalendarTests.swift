import Foundation
import Testing
@testable import TranscriptsKit

/// Which calendar events count as the user's meetings.
@Suite struct MeetingFilterTests {
    let me = EventPerson(email: "lukas@example.com", isCurrentUser: true)
    let anna = EventPerson(email: "anna@example.com", isCurrentUser: false)
    let tim = EventPerson(email: "tim@example.com", isCurrentUser: false)
    /// A team's shared calendar organizes its own events.
    let team = EventPerson(email: "e3nn294@group.calendar.google.com", isCurrentUser: false)
    let room = EventPerson(email: "room-2@example.com", isCurrentUser: false, isPerson: false)

    @Test func invitedOrOrganizingIsMine() {
        #expect(EventPerson.includesUser(attendees: [anna, me], organizer: tim, ownAddresses: []))
        #expect(EventPerson.includesUser(attendees: [anna, tim], organizer: me, ownAddresses: []))
    }

    @Test func guestsWithoutTheUserAreSomeoneElses() {
        // "Bayer weekly" in the lab's calendar: five guests, the user isn't one of them.
        #expect(!EventPerson.includesUser(attendees: [anna, tim], organizer: team, ownAddresses: []))
        #expect(!EventPerson.includesUser(attendees: [anna], organizer: nil, ownAddresses: []))
    }

    @Test func withoutGuestsNothingSaysOtherwise() {
        #expect(EventPerson.includesUser(attendees: [], organizer: nil, ownAddresses: []))
        // A room alone is no guest.
        #expect(EventPerson.includesUser(attendees: [room], organizer: team, ownAddresses: []))
    }

    @Test func anotherAddressOfTheUserCounts() {
        // Invited at the work address, shown in a calendar of the private account.
        let work = EventPerson(email: "Lukas.Kaibel@FU-Berlin.de", isCurrentUser: false)
        #expect(EventPerson.includesUser(attendees: [anna, work], organizer: tim, ownAddresses: ["lukas.kaibel@fu-berlin.de"]))
    }

    @Test func hiddenSeriesAndCalendarsDropOut() {
        let lab = UpcomingMeeting(eventId: "e-andi", title: "Mathis, Andi", start: Date(), end: Date().addingTimeInterval(3600), attendees: [],
                                  joinURL: nil, app: "Google Meet", calendarId: "c-lab", calendarTitle: "Landgraf Lab FUB", isRecurring: true)
        var own = lab
        own.eventId = "e-sync"
        own.calendarId = "c-work"
        #expect(MeetingFilter().allows(lab))
        #expect(!MeetingFilter(hiddenEvents: ["e-andi"]).allows(lab))
        #expect(MeetingFilter(hiddenEvents: ["e-andi"]).allows(own))
        #expect(!MeetingFilter(hiddenCalendars: ["c-lab"]).allows(lab))
        #expect(MeetingFilter(hiddenCalendars: ["c-lab"]).allows(own))
    }
}

@MainActor
@Suite(.serialized) struct HideMeetingTests {
    func makeModel() throws -> AppModel {
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let model = AppModel(database: try AppDatabase.inMemory(), settings: AppSettings(defaults: defaults), secrets: MemorySecretStore(), isDemo: true)
        model.loadDemoState()
        return model
    }

    @Test func hidingASeriesRemovesItAndUndoBringsItBack() throws {
        let model = try makeModel()
        let planning = try #require(model.upcoming.first { $0.eventId == "e-planning" })
        model.hide(.meeting(planning))
        #expect(!model.upcoming.contains { $0.eventId == "e-planning" })
        #expect(model.upcoming.contains { $0.eventId == "e-hoffmann" })
        #expect(model.settings.hiddenMeetings.map(\.id) == ["event:e-planning"])
        #expect(model.settings.hiddenMeetings.first?.isRecurring == true)
        #expect(model.settings.hiddenMeetings.first?.calendarTitle == planning.calendarTitle)
        // The toast offers the way back.
        #expect(model.toasts.last?.action == .unhide(.meeting(planning)))
        model.perform(.unhide(.meeting(planning)))
        #expect(model.upcoming.contains { $0.eventId == "e-planning" })
        #expect(model.settings.hiddenMeetings.isEmpty)
    }

    @Test func hidingACalendarRemovesAllOfItsMeetings() throws {
        let model = try makeModel()
        let hoffmann = try #require(model.upcoming.first { $0.eventId == "e-hoffmann" })
        model.hide(try #require(HiddenCalendarItem.calendar(of: hoffmann)))
        #expect(model.upcoming.map(\.eventId) == ["e-planning"])
        #expect(model.settings.hiddenMeetings.first?.kind == .calendar)
        #expect(model.settings.hiddenMeetings.first?.title == hoffmann.calendarTitle)
    }

    @Test func notMineFromAReminderHidesTheSeries() throws {
        let model = try makeModel()
        model.handle(.notMine(eventId: "e-planning", title: "Sprint Planning 43"))
        #expect(!model.upcoming.contains { $0.eventId == "e-planning" })
        // Known from the calendar: stored with its calendar and as a series.
        #expect(model.settings.hiddenMeetings.first?.isRecurring == true)
        // Hiding twice keeps one entry.
        model.handle(.notMine(eventId: "e-planning", title: "Sprint Planning 43"))
        #expect(model.settings.hiddenMeetings.count == 1)
    }

    @Test func hiddenItemsSurviveARestart() throws {
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.hiddenMeetings = [HiddenCalendarItem(kind: .calendar, identifier: "c-lab", title: "Landgraf Lab FUB")]
        settings.onlyMyMeetings = false
        let again = AppSettings(defaults: defaults)
        #expect(again.hiddenMeetings.map(\.id) == ["calendar:c-lab"])
        #expect(again.onlyMyMeetings == false)
        #expect(AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!).onlyMyMeetings)
    }
}
