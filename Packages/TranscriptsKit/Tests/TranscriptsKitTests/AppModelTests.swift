import Foundation
import Testing
@testable import TranscriptsKit

/// The actions behind the app's buttons, on an in-memory database.
@MainActor
@Suite(.serialized) struct AppModelTests {
    func makeModel() throws -> (AppModel, AppDatabase) {
        let database = try AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let model = AppModel(database: database, settings: AppSettings(defaults: defaults), secrets: MemorySecretStore(), isDemo: true)
        return (model, database)
    }

    /// A made-up voice: a fixed random direction, with a little variation for another recording of it.
    func voice(_ seed: UInt64, jitter: Float = 0) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
        let base = (0..<256).map { _ in next() }
        var noise = UInt64(99)
        let varied = base.map { value -> Float in
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            return value + jitter * (Float(noise % 2000) / 1000 - 1)
        }
        let norm = sqrt(varied.reduce(0) { $0 + $1 * $1 })
        return varied.map { $0 / norm }
    }

    func addMeeting(_ database: AppDatabase, id: String, attendees: [Attendee] = [], speaker: MeetingSpeaker, text: String = "Hallo zusammen") throws {
        try database.save(Meeting(id: id, title: "Meeting \(id)", status: .ready, attendees: attendees))
        let segment = Segment(meetingId: id, speakerKey: speaker.key, channel: .system, start: 0, end: 6, text: text, embedding: speaker.embedding)
        try database.replaceTranscript(meetingId: id, segments: [segment], speakers: [speaker])
    }

    func speaker(of database: AppDatabase, in meetingId: String) throws -> MeetingSpeaker {
        try #require(try database.detail(of: meetingId)?.speakers.first)
    }

    @Test func confirmingASpokenNameCreatesThePersonAndLearnsTheVoice() throws {
        let (model, database) = try makeModel()
        let suggested = MeetingSpeaker(meetingId: "a", key: "S4", label: "Sprecher 4", assignment: .suggested, suggestedName: "Jonas Weber",
                                       suggestionReason: "„Gute Idee, Jonas.“", talkTime: 30, embedding: voice(1).embeddingData)
        try addMeeting(database, id: "a", attendees: [Attendee(name: "Jonas Weber", email: "jonas@example.com")], speaker: suggested)

        // Confirmed from the people list: no meeting is open.
        model.confirmSuggestion(suggested)

        let jonas = try #require(try database.people().first { $0.name == "Jonas Weber" })
        #expect(jonas.email == "jonas@example.com")
        let confirmed = try speaker(of: database, in: "a")
        #expect(confirmed.personId == jonas.id)
        #expect(confirmed.assignment == .confirmed)
        #expect(try database.voiceSamples().contains { $0.personId == jonas.id && $0.source == .confirmed })
        #expect(try database.voiceReviews(limit: 10).isEmpty)
    }

    /// Waits for the background voice check to settle.
    func voicesSettled(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if model.voiceRefresh == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aLearnedVoiceIsRecognisedInOtherMeetings() async throws {
        let (model, database) = try makeModel()
        let first = MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", talkTime: 40, embedding: voice(7).embeddingData)
        let later = MeetingSpeaker(meetingId: "b", key: "S2", label: "Sprecher 2", talkTime: 25, embedding: voice(7, jitter: 0.05).embeddingData)
        let stranger = MeetingSpeaker(meetingId: "c", key: "S1", label: "Sprecher 1", talkTime: 25, embedding: voice(8).embeddingData)
        try addMeeting(database, id: "a", speaker: first)
        try addMeeting(database, id: "b", speaker: later)
        try addMeeting(database, id: "c", speaker: stranger)

        model.assign(first, toNewPersonNamed: "Thomas Klein")

        let thomas = try #require(try database.people().first { $0.name == "Thomas Klein" })
        try await voicesSettled(model)
        let recognised = try speaker(of: database, in: "b")
        #expect(recognised.assignment == .automatic)
        #expect(recognised.personId == thomas.id)
        #expect(try speaker(of: database, in: "c").assignment == .unknown)
        #expect(model.voiceLibrary.profiles[thomas.id]?.hasVoice == true)
    }

    /// The case from the first real meetings: a voice confirmed as the wrong person. Everything the app
    /// concluded from that follows the correction.
    @Test func correctingAConfirmedVoiceCorrectsWhatFollowedFromIt() async throws {
        let (model, database) = try makeModel()
        let hai = MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", talkTime: 40, embedding: voice(21).embeddingData)
        let haiAgain = MeetingSpeaker(meetingId: "b", key: "S1", label: "Sprecher 1", talkTime: 30, embedding: voice(21, jitter: 0.05).embeddingData)
        try addMeeting(database, id: "a", speaker: hai)
        try addMeeting(database, id: "b", speaker: haiAgain)

        model.assign(hai, toNewPersonNamed: "Sven")
        try await voicesSettled(model)
        let sven = try #require(try database.people().first { $0.name == "Sven" })
        #expect(try speaker(of: database, in: "b").personId == sven.id)

        model.assign(try speaker(of: database, in: "a"), toNewPersonNamed: "Hai")
        try await voicesSettled(model)
        let haiPerson = try #require(try database.people().first { $0.name == "Hai" })
        let corrected = try speaker(of: database, in: "b")
        #expect(corrected.personId == haiPerson.id)
        #expect(corrected.assignment == .automatic)
        #expect(model.voiceLibrary.profiles[sven.id]?.hasVoice != true)
    }

    @Test func aRejectedPersonIsNotSuggestedAgain() async throws {
        let (model, database) = try makeModel()
        let known = MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", talkTime: 40, embedding: voice(31).embeddingData)
        let alike = MeetingSpeaker(meetingId: "b", key: "S1", label: "Sprecher 1", talkTime: 30, embedding: voice(31, jitter: 0.05).embeddingData)
        try addMeeting(database, id: "a", speaker: known)
        try addMeeting(database, id: "b", speaker: alike)
        model.assign(known, toNewPersonNamed: "Anna")
        try await voicesSettled(model)
        #expect(try speaker(of: database, in: "b").assignment == .automatic)

        model.unassign(try speaker(of: database, in: "b"))
        try await voicesSettled(model)
        let after = try speaker(of: database, in: "b")
        #expect(after.assignment == .unknown)
        #expect(after.personId == nil)
    }

    @Test func linesOfAnotherVoiceCanBeGivenToTheirPerson() async throws {
        let (model, database) = try makeModel()
        try database.save(Meeting(id: "a", title: "Sync", status: .ready))
        let mine = voice(41), other = voice(42)
        try database.replaceTranscript(meetingId: "a", segments: [
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 9, text: "Eins", embedding: mine.embeddingData),
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 10, end: 19, text: "Zwei", embedding: other.embeddingData),
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 20, end: 29, text: "Drei", embedding: voice(41, jitter: 0.05).embeddingData),
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 30, end: 39, text: "Vier", embedding: voice(42, jitter: 0.05).embeddingData),
        ], speakers: [MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", talkTime: 36)])
        let detail = try #require(try database.detail(of: "a"))
        let groups = SpeakerVoices.notable(SpeakerVoices.groups(of: detail.segments)["S1"] ?? [])
        #expect(groups.count == 2)
        let julian = try database.person(named: "Julian")
        let second = try #require(groups.first { $0.segmentIds.contains(detail.segments[1].id!) })
        #expect(Set(second.segmentIds) == Set([detail.segments[1].id!, detail.segments[3].id!]))

        model.assignLines(second.segmentIds, in: "a", to: julian.id)
        try await voicesSettled(model)
        let after = try #require(try database.detail(of: "a"))
        #expect(after.segments.map(\.speakerKey) == ["S1", "S2", "S1", "S2"])
        #expect(after.speaker(for: "S2")?.personId == julian.id)
        #expect(after.speaker(for: "S2")?.assignment == .confirmed)
        #expect(after.speaker(for: "S1")?.personId == nil)
    }

    @Test func rejectingASuggestionLeavesAnUnknownVoice() throws {
        let (model, database) = try makeModel()
        let suggested = MeetingSpeaker(meetingId: "a", key: "S2", label: "Sprecher 2", assignment: .suggested, suggestedName: "Paula",
                                       suggestionReason: "„Hier ist Paula“", confidence: 0.6, talkTime: 12)
        try addMeeting(database, id: "a", speaker: suggested)

        model.rejectSuggestion(suggested)

        let rejected = try speaker(of: database, in: "a")
        #expect(rejected.assignment == .unknown)
        #expect(rejected.suggestedName == nil)
        #expect(rejected.suggestionReason == nil)
        #expect(try database.people().isEmpty)
    }

    @Test func markdownExportHasSummaryTasksMarkersAndTranscript() throws {
        let (model, database) = try makeModel()
        let anna = Person(id: "anna", name: "Anna Berger")
        try database.save(anna)
        try database.save(Meeting(id: "a", title: "Weekly Produkt-Sync", status: .ready))
        try database.replaceTranscript(meetingId: "a", segments: [
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 4, text: "Dann verschieben wir das Release."),
            Segment(meetingId: "a", speakerKey: "me", channel: .microphone, start: 65, end: 70, text: "Ich übernehme die Interviews."),
        ], speakers: [
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", personId: anna.id, assignment: .confirmed, talkTime: 4),
            MeetingSpeaker(meetingId: "a", key: "me", label: Strings.me, talkTime: 5, channel: .microphone),
        ])
        try database.save(summary: MeetingSummary(meetingId: "a", overview: "Das Release wird verschoben.", decisions: ["Release am 14. Oktober"],
                                                  openQuestions: ["Wer informiert die Kunden?"], model: "m", provider: "p"),
                          actionItems: [ActionItem(meetingId: "a", text: "Interviews führen", owner: "Lukas", due: "Donnerstag")])
        _ = try database.addMarker(Marker(meetingId: "a", time: 62, text: "Budget klären"))
        let detail = try #require(try database.detail(of: "a"))

        let markdown = model.markdown(for: detail)

        #expect(markdown.hasPrefix("# Weekly Produkt-Sync\n"))
        #expect(markdown.contains("## Zusammenfassung\n\nDas Release wird verschoben."))
        #expect(markdown.contains("### Entscheidungen\n\n- Release am 14. Oktober"))
        #expect(markdown.contains("- [ ] Interviews führen (Lukas, Donnerstag)"))
        #expect(markdown.contains("### Offene Fragen\n\n- Wer informiert die Kunden?"))
        #expect(markdown.contains("- 01:02 Budget klären"))
        #expect(markdown.contains("**Anna Berger** (00:00): Dann verschieben wir das Release."))
        // The user's lines carry their name, not "Du".
        #expect(markdown.contains("**\(model.myName)** (01:05): Ich übernehme die Interviews."))
    }

    @Test func renamingAndDeletingMeetings() throws {
        let (model, database) = try makeModel()
        let id = "test-\(UUID().uuidString)"
        try addMeeting(database, id: id, speaker: MeetingSpeaker(meetingId: id, key: "S1", label: "Sprecher 1", talkTime: 6))

        model.rename(meetingId: id, to: "  ")
        #expect(try database.detail(of: id)?.meeting.title == "Meeting \(id)")
        model.rename(meetingId: id, to: " Kundencall Hoffmann ")
        let renamed = try #require(try database.detail(of: id)?.meeting)
        #expect(renamed.title == "Kundencall Hoffmann")
        #expect(renamed.titleIsCustom)

        model.deleteMeeting(id)
        #expect(try database.detail(of: id) == nil)
    }

    @Test func confirmingASpokenFirstNameLiveUsesThePersonTheAppKnows() throws {
        let database = try AppDatabase.inMemory()
        let thomas = try database.person(named: "Thomas Klein")
        let meeting = Meeting(title: "Sprint Planning", status: .recording, attendees: [Attendee(name: "Paula Schmidt", email: "paula@example.com")])
        try database.save(meeting)
        let session = RecordingSession(meeting: meeting, database: database, configuration: .init(), sources: [:])
        session.loadDemoLines()

        session.confirm("S4", as: "Thomas")
        #expect(session.voices["S4"]?.personId == thomas.id)
        #expect(try database.people().filter { $0.name.hasPrefix("Thomas") }.count == 1)

        // A first name of an invitee becomes the calendar's full name, with the address.
        session.confirm("S3", as: "Paula")
        let paula = try #require(try database.people().first { $0.name == "Paula Schmidt" })
        #expect(paula.email == "paula@example.com")
        #expect(session.voices["S3"]?.name == "Paula Schmidt")
    }

    @Test func everyAppIconHasItsPictureAndTheChoiceIsKept() throws {
        for choice in AppIconChoice.allCases {
            let image = try #require(choice.image, "no picture for \(choice)")
            #expect(image.size.width > 0)
        }
        let defaults = UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.appIcon == .automatic)
        settings.appIcon = .indigo
        #expect(AppSettings(defaults: defaults).appIcon == .indigo)
    }

    @Test func peopleCanBeRenamedButMeIsNeverDeleted() throws {
        let (model, database) = try makeModel()
        let me = try database.mePerson(defaultName: "Lukas Kaibel")
        let guest = try database.person(named: "Daniel Hofmann")

        model.rename(guest, to: "Daniel Hoffmann")
        model.delete(me)

        let people = try database.people()
        #expect(people.contains { $0.id == me.id })
        #expect(people.first { $0.id == guest.id }?.name == "Daniel Hoffmann")
    }
}
