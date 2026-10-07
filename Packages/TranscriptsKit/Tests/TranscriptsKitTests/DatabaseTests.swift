import Foundation
import GRDB
import Testing
@testable import TranscriptsKit

@Suite struct DatabaseTests {
    func makeMeeting(_ database: AppDatabase, id: String = "m1", title: String = "Weekly", lines: [(String, String)] = []) throws {
        try database.save(Meeting(id: id, title: title, status: .ready))
        let segments = lines.enumerated().map { index, line in
            Segment(meetingId: id, speakerKey: line.0, channel: line.0 == "me" ? .microphone : .system, start: Double(index * 5), end: Double(index * 5 + 4), text: line.1)
        }
        let keys = Set(lines.map(\.0))
        let speakers = keys.sorted().map { MeetingSpeaker(meetingId: id, key: $0, label: $0 == "me" ? Strings.meLabel : "Sprecher \($0.dropFirst())", talkTime: 8, channel: $0 == "me" ? .microphone : .system) }
        try database.replaceTranscript(meetingId: id, segments: segments, speakers: speakers)
    }

    @Test func detailReadsEverything() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("S1", "Hallo zusammen"), ("me", "Hi Anna")])
        try database.save(summary: MeetingSummary(meetingId: "m1", overview: "Kurz", decisions: ["A"], openQuestions: [], model: "x", provider: "y"),
                          actionItems: [ActionItem(meetingId: "m1", text: "Eins"), ActionItem(meetingId: "m1", text: "Zwei")])
        _ = try database.addMarker(Marker(meetingId: "m1", time: 3, text: "Wichtig"))
        let detail = try #require(try database.detail(of: "m1"))
        #expect(detail.segments.map(\.text) == ["Hallo zusammen", "Hi Anna"])
        #expect(detail.speakers.count == 2)
        #expect(detail.summary?.decisions == ["A"])
        #expect(detail.actionItems.map(\.text) == ["Eins", "Zwei"])
        #expect(detail.actionItems.map(\.position) == [0, 1])
        #expect(detail.markers.count == 1)
        #expect(detail.displayName(for: "me") == Strings.me)
        #expect(detail.displayName(for: "S1") == "Sprecher 1")
    }

    @Test func fullTextSearchFindsPrefixesAcrossMeetings() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, id: "a", title: "Release", lines: [("S1", "Der PDF-Export ist kaputt")])
        try makeMeeting(database, id: "b", title: "Onboarding", lines: [("S1", "Das Formular ist zu lang")])
        let hits = try database.search("formu")
        #expect(hits.map(\.meetingTitle) == ["Onboarding"])
        #expect(hits.first?.snippet.contains("«Formular»") == true)
        #expect(try database.search("").isEmpty)
    }

    @Test func deletingAMeetingRemovesItsRows() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("S1", "Hallo")])
        try database.deleteMeeting("m1")
        let counts = try database.reader.read { db in
            (try Segment.fetchCount(db), try MeetingSpeaker.fetchCount(db))
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    @Test func mergingPeopleMovesVoicesAndAssignments() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("S1", "Hallo")])
        let anna = Person(id: "anna", name: "Anna")
        let annaDuplicate = Person(id: "anna2", name: "Anna B.")
        try database.save(anna)
        try database.save(annaDuplicate)
        try database.save(Voiceprint(personId: "anna2", embedding: [Float](repeating: 0.1, count: 4).embeddingData, meetingId: nil, duration: 10))
        var speaker = try #require(try database.detail(of: "m1")?.speakers.first)
        speaker.personId = "anna2"
        speaker.assignment = .confirmed
        try database.save(speaker)
        try database.mergePerson("anna2", into: "anna")
        #expect(try database.people().map(\.id) == ["anna"])
        #expect(try database.voiceprints().map(\.personId) == ["anna"])
        #expect(try database.detail(of: "m1")?.speakers.first?.personId == "anna")
    }

    @Test func deletingAPersonLeavesUnknownVoices() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("S1", "Hallo")])
        try database.save(Person(id: "p", name: "Paula"))
        var speaker = try #require(try database.detail(of: "m1")?.speakers.first)
        speaker.personId = "p"
        speaker.assignment = .confirmed
        try database.save(speaker)
        try database.deletePerson("p")
        let after = try #require(try database.detail(of: "m1")?.speakers.first)
        #expect(after.personId == nil)
        #expect(after.assignment == .unknown)
    }

    @Test func voicesAreLearnedFromTheLinesOfKnownPeople() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "anna", name: "Anna"))
        try database.save(Person(id: "me", name: "Lukas", isMe: true))
        try database.save(Meeting(id: "m1", title: "Weekly", status: .ready))
        let voice = [Float](repeating: 0.5, count: 4).embeddingData
        try database.replaceTranscript(meetingId: "m1", segments: [
            Segment(meetingId: "m1", speakerKey: "S1", channel: .system, start: 0, end: 5, text: "Hallo", embedding: voice),
            Segment(meetingId: "m1", speakerKey: "S1", channel: .system, start: 5, end: 9, text: "Hm", embedding: voice, voiceIgnored: true),
            Segment(meetingId: "m1", speakerKey: "S2", channel: .system, start: 9, end: 14, text: "Wer bin ich?", embedding: voice),
            Segment(meetingId: "m1", speakerKey: "S3", channel: .system, start: 14, end: 19, text: "Erkannt", embedding: voice),
            Segment(meetingId: "m1", speakerKey: "me", channel: .microphone, start: 19, end: 24, text: "Ich", embedding: voice),
            Segment(meetingId: "m1", speakerKey: "S1", channel: .system, start: 24, end: 25, text: "Ja"),
        ], speakers: [
            MeetingSpeaker(meetingId: "m1", key: "S1", label: "Sprecher 1", personId: "anna", assignment: .confirmed),
            MeetingSpeaker(meetingId: "m1", key: "S2", label: "Sprecher 2", assignment: .unknown),
            MeetingSpeaker(meetingId: "m1", key: "S3", label: "Sprecher 3", personId: "anna", assignment: .automatic),
            MeetingSpeaker(meetingId: "m1", key: "me", label: Strings.meLabel, personId: "me", assignment: .confirmed, channel: .microphone),
        ])
        // An old averaged sample stands in only where its meeting has no lines of that person.
        try database.save(Voiceprint(personId: "anna", embedding: voice, meetingId: "m1", duration: 30))
        try database.save(Voiceprint(personId: "anna", embedding: voice, meetingId: nil, duration: 30))

        let samples = try database.voiceSamples()
        let anna = samples.filter { $0.personId == "anna" }
        #expect(anna.filter { $0.source == .confirmed }.count == 2)
        #expect(anna.filter { $0.source == .confirmed && $0.ignored }.count == 1)
        #expect(anna.filter { $0.source == .automatic }.count == 1)
        #expect(anna.filter { $0.source == .legacy }.count == 1)
        #expect(samples.filter { $0.personId == "me" }.map(\.source) == [.microphone])
        #expect(anna.first { $0.source == .confirmed && !$0.ignored }?.start == 0)

        let stats = try #require(try database.peopleStats().first { $0.person.id == "anna" })
        #expect(stats.voiceSamples == 3)
    }

    @Test func movingLinesSplitsASpeaker() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "hai", name: "Hai"))
        try makeMeeting(database, lines: [("S1", "Eins"), ("S1", "Zwei"), ("S1", "Drei"), ("S2", "Vier")])
        let lines = try #require(try database.detail(of: "m1")?.segments)
        let key = try database.moveLines([lines[1].id!, lines[2].id!], in: "m1", toPerson: "hai")
        let detail = try #require(try database.detail(of: "m1"))
        let moved = try #require(detail.speaker(for: key ?? ""))
        #expect(moved.key == "S3")
        #expect(moved.label == "Sprecher 3")
        #expect(moved.personId == "hai")
        #expect(moved.assignment == .confirmed)
        #expect(moved.talkTime == 8)
        #expect(detail.segments.map(\.speakerKey) == ["S1", "S3", "S3", "S2"])
        #expect(detail.speaker(for: "S1")?.talkTime == 4)

        // Lines of the same person join their voice; a speaker left without lines is gone.
        _ = try database.moveLines([lines[0].id!], in: "m1", toPerson: "hai")
        let after = try #require(try database.detail(of: "m1"))
        #expect(after.speaker(for: "S1") == nil)
        #expect(after.segments.map(\.speakerKey) == ["S3", "S3", "S3", "S2"])

        let separate = try database.moveLinesToNewVoice([lines[3].id!], in: "m1")
        #expect(separate == "S1")
        #expect(try database.detail(of: "m1")?.speaker(for: "S2") == nil)
    }

    @Test func olderDatabasesGainLineVoices() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meeting (id, title, startedAt, status, origin, createdAt) VALUES ('m', 'Alt', '2026-10-06 08:00:00', 'ready', 'recording', '2026-10-06 08:00:00')")
            try db.execute(sql: "INSERT INTO segment (meetingId, speakerKey, channel, start, \"end\", text) VALUES ('m', 'S1', 'system', 0, 5, 'Hallo')")
            try db.execute(sql: "INSERT INTO meetingSpeaker (meetingId, \"key\", label, assignment, channel) VALUES ('m', 'S1', 'Sprecher 1', 'unknown', 'system')")
        }
        let database = try AppDatabase(queue)
        let detail = try #require(try database.detail(of: "m"))
        #expect(detail.segments.first?.embedding == nil)
        #expect(detail.segments.first?.voiceIgnored == false)
        #expect(detail.speakers.first?.rejectedPersonIds == [])
        #expect(detail.speakers.first?.candidatePersonIds == [])
        #expect(detail.segments.first?.placement == nil)
        #expect(try database.meetingsWithoutLineVoices().map(\.id) == ["m"])
    }

    @Test func peopleStatsAndReviews() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("S1", "Hallo"), ("S2", "Hi")])
        try database.save(Person(id: "anna", name: "Anna"))
        var speakers = try #require(try database.detail(of: "m1")?.speakers)
        speakers[0].personId = "anna"
        speakers[0].assignment = .automatic
        speakers[1].assignment = .suggested
        speakers[1].suggestedPersonId = "anna"
        for speaker in speakers { try database.save(speaker) }
        let stats = try database.peopleStats()
        #expect(stats.first { $0.person.id == "anna" }?.meetings == 1)
        let reviews = try database.voiceReviews()
        #expect(reviews.count == 1)
        #expect(reviews.first?.suggestedPerson?.name == "Anna")
    }

    @Test func meIsCreatedOnce() throws {
        let database = try AppDatabase.inMemory()
        let first = try database.mePerson(defaultName: "Lukas")
        let second = try database.mePerson(defaultName: "Someone else")
        #expect(first.id == second.id)
        #expect(second.name == "Lukas")
    }

    @Test func meetingRowsCountPendingVoices() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, lines: [("me", "Hallo"), ("S1", "Hi")])
        let row = try #require(try database.meetingRows().first)
        #expect(row.pendingVoices == 1)
        #expect(row.hasSummary == false)
    }
}

@Suite struct DemoDataTests {
    @Test func demoDataLoads() throws {
        let database = try AppDatabase.inMemory()
        DemoData.seed(database)
        let rows = try database.meetingRows()
        #expect(rows.count == 9)
        #expect(try database.detail(of: "m-sync")?.segments.count == 15)
        #expect(try database.voiceReviews().count == 3)
    }
}
