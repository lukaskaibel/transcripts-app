import Foundation
import GRDB

/// A person with how much the app has heard from them.
public struct PersonStats: Equatable, Identifiable, Sendable {
    public var person: Person
    public var meetings: Int
    public var talkTime: Double
    public var lastSeen: Date?
    /// Lines (and older averaged samples) the app learns this voice from.
    public var voiceSamples: Int
    /// Seconds of speech behind them.
    public var voiceSpeech: Double
    /// Meetings they come from.
    public var voiceMeetings: Int

    public var id: String { person.id }

    public init(person: Person, meetings: Int, talkTime: Double, lastSeen: Date?, voiceSamples: Int, voiceSpeech: Double = 0, voiceMeetings: Int = 0) {
        self.person = person
        self.meetings = meetings
        self.talkTime = talkTime
        self.lastSeen = lastSeen
        self.voiceSamples = voiceSamples
        self.voiceSpeech = voiceSpeech
        self.voiceMeetings = voiceMeetings
    }

    /// 0 none, 1 weak, 2 medium, 3 good: how well the app knows this voice.
    public var voiceQuality: Int {
        if voiceSamples == 0 { return 0 }
        if voiceSpeech < 60 { return 1 }
        if voiceSpeech < 300 || voiceMeetings < 2 { return 2 }
        return 3
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
            // What each person's voice is learned from: their lines with embeddings, plus older averaged
            // samples where their meeting has no such lines.
            var voices: [String: (count: Int, speech: Double, meetings: Int)] = [:]
            let lines = try Row.fetchAll(db, sql: """
                SELECT meetingSpeaker.personId AS personId, COUNT(*) AS count,
                       SUM(segment."end" - segment.start) AS speech, COUNT(DISTINCT segment.meetingId) AS meetings
                FROM segment
                JOIN meetingSpeaker ON meetingSpeaker.meetingId = segment.meetingId AND meetingSpeaker."key" = segment.speakerKey
                WHERE segment.embedding IS NOT NULL AND segment.voiceIgnored = 0 AND meetingSpeaker.personId IS NOT NULL
                  AND meetingSpeaker.assignment IN ('confirmed', 'automatic')
                GROUP BY meetingSpeaker.personId
                """)
            for row in lines {
                voices[row["personId"]] = (row["count"], row["speech"] ?? 0, row["meetings"])
            }
            let prints = try Row.fetchAll(db, sql: """
                SELECT personId, COUNT(*) AS count, SUM(duration) AS speech FROM voiceprint
                WHERE voiceprint.meetingId IS NULL OR (
                    NOT EXISTS (SELECT 1 FROM segment WHERE segment.meetingId = voiceprint.meetingId AND segment.embedding IS NOT NULL)
                    AND EXISTS (
                        SELECT 1 FROM meetingSpeaker
                        WHERE meetingSpeaker.meetingId = voiceprint.meetingId AND meetingSpeaker.personId = voiceprint.personId
                          AND meetingSpeaker.assignment IN ('confirmed', 'automatic')
                    )
                )
                GROUP BY personId
                """)
            for row in prints {
                let personId: String = row["personId"]
                let entry = voices[personId] ?? (0, 0, 0)
                let count: Int = row["count"]
                voices[personId] = (entry.count + count, entry.speech + (row["speech"] ?? 0), entry.meetings + count)
            }
            return people.map { person in
                let entry = stats[person.id]
                let voice = voices[person.id]
                return PersonStats(
                    person: person, meetings: entry?.0 ?? 0, talkTime: entry?.1 ?? 0, lastSeen: entry?.2,
                    voiceSamples: voice?.count ?? 0, voiceSpeech: voice?.speech ?? 0, voiceMeetings: voice?.meetings ?? 0
                )
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
    /// Names a voice for good: the speaker is confirmed as `personId`. Its lines then count for that
    /// person's voice, so later meetings recognise them.
    public func assign(_ speaker: MeetingSpeaker, to personId: String) throws {
        try writer.write { db in
            guard var speaker = try MeetingSpeaker.fetchOne(db, key: ["meetingId": speaker.meetingId, "key": speaker.key]) else { return }
            speaker.personId = personId
            speaker.assignment = .confirmed
            speaker.suggestedPersonId = nil
            speaker.suggestedName = nil
            speaker.suggestionReason = nil
            speaker.candidatePersonIds = []
            speaker.confidence = 1
            try speaker.update(db)
        }
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
