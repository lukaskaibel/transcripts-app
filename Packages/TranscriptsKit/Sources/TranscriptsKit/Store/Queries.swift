import Foundation
import GRDB

/// A person with how much the app has heard from them.
public struct PersonStats: Equatable, Identifiable, Sendable {
    public var person: Person
    public var meetings: Int
    public var talkTime: Double
    public var lastSeen: Date?
    public var voiceprints: Int

    public var id: String { person.id }

    /// 0 none, 1 weak, 2 medium, 3 good: how well the app knows this voice.
    public var voiceQuality: Int {
        switch (voiceprints, talkTime) {
        case (0, _): 0
        case (1, ..<120): 1
        case (1, _), (2...3, ..<300): 2
        default: voiceprints >= 2 ? 3 : 2
        }
    }
}

/// A voice in some meeting that waits for the user: a suggestion to confirm or an unknown voice to name.
public struct VoiceReview: Equatable, Identifiable, Sendable {
    public var speaker: MeetingSpeaker
    public var meetingTitle: String
    public var meetingDate: Date
    public var suggestedPerson: Person?

    public var id: String { speaker.id }
}

extension AppDatabase {
    public func peopleStats() throws -> [PersonStats] {
        try reader.read { db in try Self.fetchPeopleStats(db) }
    }

    public func voiceReviews(limit: Int = 50) throws -> [VoiceReview] {
        try reader.read { db in try Self.fetchVoiceReviews(db, limit: limit) }
    }

    static func fetchPeopleStats(_ db: Database) throws -> [PersonStats] {
        do {
            let people = try Person.fetchAll(db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT meetingSpeaker.personId AS personId,
                       COUNT(DISTINCT meetingSpeaker.meetingId) AS meetings,
                       SUM(meetingSpeaker.talkTime) AS talk,
                       MAX(meeting.startedAt) AS lastSeen
                FROM meetingSpeaker JOIN meeting ON meeting.id = meetingSpeaker.meetingId
                WHERE meetingSpeaker.personId IS NOT NULL
                GROUP BY meetingSpeaker.personId
                """)
            var stats: [String: (Int, Double, Date?)] = [:]
            for row in rows {
                stats[row["personId"]] = (row["meetings"], row["talk"] ?? 0, row["lastSeen"])
            }
            let prints = try Row.fetchAll(db, sql: "SELECT personId, COUNT(*) AS count FROM voiceprint GROUP BY personId")
            var printCounts: [String: Int] = [:]
            for row in prints { printCounts[row["personId"]] = row["count"] }
            return people.map { person in
                let entry = stats[person.id]
                return PersonStats(person: person, meetings: entry?.0 ?? 0, talkTime: entry?.1 ?? 0, lastSeen: entry?.2, voiceprints: printCounts[person.id] ?? 0)
            }
            .sorted { lhs, rhs in
                if lhs.person.isMe != rhs.person.isMe { return lhs.person.isMe }
                if lhs.talkTime != rhs.talkTime { return lhs.talkTime > rhs.talkTime }
                return lhs.person.name.localizedCaseInsensitiveCompare(rhs.person.name) == .orderedAscending
            }
        }
    }

    /// Voices that wait for the user, newest meetings first. Very short voices (a cough, one "ja") are left out.
    static func fetchVoiceReviews(_ db: Database, limit: Int = 50) throws -> [VoiceReview] {
        do {
            let rows = try Row.fetchAll(db, sql: """
                SELECT meetingSpeaker.*, meeting.title AS meetingTitle, meeting.startedAt AS meetingDate
                FROM meetingSpeaker JOIN meeting ON meeting.id = meetingSpeaker.meetingId
                WHERE meetingSpeaker.key != 'me'
                  AND meetingSpeaker.assignment IN ('suggested', 'unknown')
                  AND meetingSpeaker.talkTime >= 4
                  AND meeting.status = 'ready'
                ORDER BY meeting.startedAt DESC, meetingSpeaker.talkTime DESC
                LIMIT ?
                """, arguments: [limit])
            let speakers = try rows.map { try MeetingSpeaker(row: $0) }
            let personIds = Set(speakers.compactMap(\.suggestedPersonId))
            let people = Dictionary(uniqueKeysWithValues: try Person.filter(keys: Array(personIds)).fetchAll(db).map { ($0.id, $0) })
            return zip(rows, speakers).map { row, speaker in
                VoiceReview(
                    speaker: speaker,
                    meetingTitle: row["meetingTitle"],
                    meetingDate: row["meetingDate"],
                    suggestedPerson: speaker.suggestedPersonId.flatMap { people[$0] }
                )
            }
        }
    }

    public func meetings(of personId: String) throws -> [Meeting] {
        try reader.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT DISTINCT meeting.* FROM meeting
                JOIN meetingSpeaker ON meetingSpeaker.meetingId = meeting.id
                WHERE meetingSpeaker.personId = ?
                ORDER BY meeting.startedAt DESC
                """, arguments: [personId])
        }
    }

    /// Meetings still marked as recording or processing when the app starts: the app quit in the middle.
    public func interruptedMeetings() throws -> [Meeting] {
        try reader.read { db in
            try Meeting.filter([Meeting.Status.recording.rawValue, Meeting.Status.processing.rawValue].contains(Column("status"))).fetchAll(db)
        }
    }
}

extension AppDatabase {
    /// Names a voice for good: the speaker is confirmed as `personId`, and its voice is kept as a sample
    /// of that person (unless it repeats one already kept), so later meetings recognise them.
    public func assign(_ speaker: MeetingSpeaker, to personId: String, maxVoiceprints: Int = 15) throws {
        var speaker = speaker
        speaker.personId = personId
        speaker.assignment = .confirmed
        speaker.suggestedPersonId = nil
        speaker.suggestedName = nil
        speaker.suggestionReason = nil
        speaker.confidence = 1
        try save(speaker)
        guard let embedding = speaker.embedding, speaker.talkTime >= 3 else { return }
        let vector = [Float](embeddingData: embedding)
        let existing = try reader.read { db in try Voiceprint.filter(Column("personId") == personId).fetchAll(db) }
        if existing.contains(where: { VoiceMath.cosine([Float](embeddingData: $0.embedding), vector) >= 0.93 }) { return }
        try save(Voiceprint(personId: personId, embedding: embedding, meetingId: speaker.meetingId, duration: speaker.talkTime))
        try trimVoiceprints(of: personId, keeping: maxVoiceprints)
    }

    /// The person with this name, created if there is none yet.
    public func person(named name: String, email: String? = nil) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            if let existing = try Person.filter(Column("isMe") == false).fetchAll(db).first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                return existing
            }
            let person = Person(name: trimmed, email: email)
            try person.insert(db)
            return person
        }
    }
}
