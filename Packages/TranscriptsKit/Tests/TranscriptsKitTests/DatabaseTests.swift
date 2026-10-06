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
        let speakers = keys.sorted().map { MeetingSpeaker(meetingId: id, key: $0, label: $0 == "me" ? Strings.me : "Sprecher \($0.dropFirst())", talkTime: 8, channel: $0 == "me" ? .microphone : .system) }
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

    @Test func voiceprintsAreTrimmedToTheNewest() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "p", name: "P"))
        for index in 0..<20 {
            try database.save(Voiceprint(personId: "p", embedding: [Float(index)].embeddingData, meetingId: nil, duration: 1, createdAt: Date().addingTimeInterval(Double(index))))
        }
        try database.trimVoiceprints(of: "p", keeping: 15)
        let kept = try database.voiceprints().map { [Float](embeddingData: $0.embedding)[0] }.sorted()
        #expect(kept.count == 15)
        #expect(kept.first == 5)
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
        #expect(try database.detail(of: "m-sync")?.segments.count == 11)
        #expect(try database.voiceReviews().count == 2)
    }
}
