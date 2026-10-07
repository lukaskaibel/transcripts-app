import Foundation
import GRDB

// MARK: - Reading voices

extension AppDatabase {
    /// Every line the app can learn voices from: lines with an embedding whose speaker is a known person,
    /// plus the averaged samples of meetings that have no such lines (their audio was deleted before lines
    /// had embeddings).
    public func voiceSamples() throws -> [VoiceSample] {
        try reader.read { db in try Self.fetchVoiceSamples(db) }
    }

    static func fetchVoiceSamples(_ db: Database) throws -> [VoiceSample] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT segment.id, segment.meetingId, segment.speakerKey, segment.start, segment."end", segment.embedding,
                   segment.voiceIgnored, segment.placement, meetingSpeaker.personId, meetingSpeaker.assignment, meeting.startedAt
            FROM segment
            JOIN meetingSpeaker ON meetingSpeaker.meetingId = segment.meetingId AND meetingSpeaker."key" = segment.speakerKey
            JOIN meeting ON meeting.id = segment.meetingId
            WHERE segment.embedding IS NOT NULL AND meetingSpeaker.personId IS NOT NULL
              AND meetingSpeaker.assignment IN ('confirmed', 'automatic')
            """)
        var samples: [VoiceSample] = rows.compactMap { row in
            guard let data: Data = row["embedding"], let personId: String = row["personId"] else { return nil }
            let key: String = row["speakerKey"]
            let assignment = MeetingSpeaker.Assignment(rawValue: row["assignment"]) ?? .automatic
            let movedByApp = (row["placement"] as String?) == Segment.Placement.app.rawValue
            let source: VoiceSample.Source = switch (key == MeetingSpeaker.meKey, assignment) {
            case _ where movedByApp: .automatic
            case (true, .confirmed): .microphone
            case (_, .confirmed): .confirmed
            default: .automatic
            }
            let id: Int64 = row["id"]
            let start: Double = row["start"]
            let end: Double = row["end"]
            return VoiceSample(
                id: "line-\(id)", personId: personId, embedding: [Float](embeddingData: data), duration: end - start,
                source: source, meetingId: row["meetingId"], segmentId: id, speakerKey: key, start: start, date: row["startedAt"],
                ignored: row["voiceIgnored"]
            )
        }
        // An averaged sample only stands in for a meeting whose lines have no embeddings (its audio is gone),
        // and only while that person is still named in it: confirmed, it counts like a confirmed line; named
        // by the app, like a recognised one.
        let embedded = Set(try String.fetchAll(db, sql: "SELECT DISTINCT meetingId FROM segment WHERE embedding IS NOT NULL"))
        var named: [String: MeetingSpeaker.Assignment] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT meetingId, personId, assignment FROM meetingSpeaker WHERE personId IS NOT NULL") {
            let key = "\(row["meetingId"] as String)/\(row["personId"] as String)"
            let assignment = MeetingSpeaker.Assignment(rawValue: row["assignment"]) ?? .unknown
            if named[key] != .confirmed { named[key] = assignment }
        }
        for print in try Voiceprint.fetchAll(db) {
            var source = VoiceSample.Source.legacy
            if let meetingId = print.meetingId {
                guard !embedded.contains(meetingId) else { continue }
                switch named["\(meetingId)/\(print.personId)"] {
                case .confirmed: source = .legacy
                case .automatic: source = .automatic
                default: continue
                }
            }
            samples.append(VoiceSample(
                id: "print-\(print.id)", personId: print.personId, embedding: [Float](embeddingData: print.embedding),
                duration: print.duration, source: source, meetingId: print.meetingId, date: print.createdAt
            ))
        }
        return samples
    }

    /// Meetings whose lines have no voice embeddings yet, but whose audio is still there to make them.
    public func meetingsWithoutLineVoices() throws -> [Meeting] {
        try reader.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT meeting.* FROM meeting
                WHERE meeting.status = 'ready'
                  AND EXISTS (SELECT 1 FROM segment WHERE segment.meetingId = meeting.id AND segment."end" - segment.start >= 1)
                  AND NOT EXISTS (SELECT 1 FROM segment WHERE segment.meetingId = meeting.id AND segment.embedding IS NOT NULL)
                ORDER BY meeting.startedAt DESC
                """)
        }
    }
}

// MARK: - Changing who said what

extension AppDatabase {
    /// Stores the voice embeddings of lines (for meetings processed before lines had them) and refreshes
    /// the speakers' own embeddings from them.
    public func saveLineEmbeddings(_ embeddings: [Int64: [Float]], meetingId: String) throws {
        try writer.write { db in
            for (id, embedding) in embeddings {
                try db.execute(sql: "UPDATE segment SET embedding = ? WHERE id = ?", arguments: [embedding.embeddingData, id])
            }
            try Self.refreshSpeakers(db, meetingId: meetingId)
        }
    }

    /// Moves lines of one meeting to the voice that is `personId` there, created if there is none, and
    /// confirms it. A speaker left without lines disappears.
    ///
    /// With `byApp`, the app moves lines that clearly sound like that person: they join the person's voice
    /// in the meeting (a new one is only recognised, not confirmed), count as recognised speech, and remember
    /// where they came from, so the user can send them back.
    @discardableResult
    public func moveLines(_ segmentIds: [Int64], in meetingId: String, toPerson personId: String, byApp: Bool = false, confidence: Double = 1) throws -> String? {
        try writer.write { db in
            let lines = try Segment.filter(keys: segmentIds).filter(Column("meetingId") == meetingId).fetchAll(db)
            guard !lines.isEmpty else { return nil }
            let speakers = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
            var target: MeetingSpeaker
            if byApp {
                // The person's voice in the meeting: named, recognised, or the one the app already guesses is them.
                if let existing = speakers.first(where: { $0.personId == personId && $0.assignment == .confirmed })
                    ?? speakers.first(where: { $0.personId == personId })
                    ?? speakers.first(where: { $0.guesses.first == personId }) {
                    target = existing
                } else {
                    target = Self.newSpeaker(meetingId: meetingId, existing: speakers, channel: lines[0].channel)
                    target.personId = personId
                    target.assignment = .automatic
                    target.confidence = confidence
                    try target.save(db)
                }
            } else {
                // Join the person's confirmed voice; a voice the app only guessed is theirs stays a guess.
                if let existing = speakers.first(where: { $0.personId == personId && $0.assignment == .confirmed }) {
                    target = existing
                } else {
                    target = Self.newSpeaker(meetingId: meetingId, existing: speakers, channel: lines[0].channel)
                }
                target.personId = personId
                target.assignment = .confirmed
                target.suggestedPersonId = nil
                target.suggestedName = nil
                target.suggestionReason = nil
                target.candidatePersonIds = []
                target.confidence = 1
                try target.save(db)
            }
            try Self.move(lines, to: target.key, placement: byApp ? .app : .user, db)
            try Self.refreshSpeakers(db, meetingId: meetingId)
            return target.key
        }
    }

    /// Keeps lines the app moved where they are now, as if the user had put them there.
    public func acceptMovedLines(_ segmentIds: [Int64]) throws {
        try writer.write { db in
            for id in segmentIds {
                try db.execute(sql: "UPDATE segment SET placement = ?, movedFromKey = NULL WHERE id = ? AND placement = ?",
                               arguments: [Segment.Placement.user.rawValue, id, Segment.Placement.app.rawValue])
            }
        }
    }

    /// Sends lines the app moved back to the speaker they came from (or a voice of their own if that one is
    /// gone), for good: the app won't move them again.
    public func returnMovedLines(_ segmentIds: [Int64], in meetingId: String) throws {
        try writer.write { db in
            let lines = try Segment.filter(keys: segmentIds).filter(Column("meetingId") == meetingId).fetchAll(db)
            var speakers = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
            for (origin, group) in Dictionary(grouping: lines, by: { $0.movedFromKey ?? "" }) {
                var key = origin
                if origin.isEmpty || !speakers.contains(where: { $0.key == origin }) {
                    let fresh = Self.newSpeaker(meetingId: meetingId, existing: speakers, channel: group[0].channel)
                    try fresh.save(db)
                    speakers.append(fresh)
                    key = fresh.key
                }
                try Self.move(group, to: key, placement: .user, db)
            }
            try Self.refreshSpeakers(db, meetingId: meetingId)
        }
    }

    /// Moves lines of one meeting to a voice of their own, not named yet.
    @discardableResult
    public func moveLinesToNewVoice(_ segmentIds: [Int64], in meetingId: String) throws -> String? {
        try writer.write { db in
            let lines = try Segment.filter(keys: segmentIds).filter(Column("meetingId") == meetingId).fetchAll(db)
            guard !lines.isEmpty else { return nil }
            let speakers = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
            let target = Self.newSpeaker(meetingId: meetingId, existing: speakers, channel: lines[0].channel)
            try target.save(db)
            try Self.move(lines, to: target.key, placement: .user, db)
            try Self.refreshSpeakers(db, meetingId: meetingId)
            return target.key
        }
    }

    /// Lines that should, or should again, count for their speaker's voice.
    public func setVoiceIgnored(_ segmentIds: [Int64], ignored: Bool) throws {
        try writer.write { db in
            var meetings = Set<String>()
            for id in segmentIds {
                try db.execute(sql: "UPDATE segment SET voiceIgnored = ? WHERE id = ?", arguments: [ignored, id])
                if let meetingId = try String.fetchOne(db, sql: "SELECT meetingId FROM segment WHERE id = ?", arguments: [id]) {
                    meetings.insert(meetingId)
                }
            }
            // The speakers' own voices change with what counts.
            for meetingId in meetings { try Self.refreshSpeakers(db, meetingId: meetingId) }
        }
    }

    /// Stops learning from everything a person said (the assignments stay).
    public func ignoreVoice(of personId: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE segment SET voiceIgnored = 1
                WHERE EXISTS (
                    SELECT 1 FROM meetingSpeaker
                    WHERE meetingSpeaker.meetingId = segment.meetingId AND meetingSpeaker."key" = segment.speakerKey
                      AND meetingSpeaker.personId = ?
                )
                """, arguments: [personId])
            _ = try Voiceprint.filter(Column("personId") == personId).deleteAll(db)
        }
    }

    private static func move(_ lines: [Segment], to key: String, placement: Segment.Placement, _ db: Database) throws {
        for var line in lines {
            guard line.speakerKey != key || line.placement != placement else { continue }
            line.movedFromKey = placement == .app ? (line.placement == .app ? line.movedFromKey : line.speakerKey) : nil
            line.speakerKey = key
            line.placement = placement
            try line.update(db, columns: ["speakerKey", "placement", "movedFromKey"])
        }
    }

    /// A fresh voice in a meeting: the next free key and the next free "Sprecher n".
    static func newSpeaker(meetingId: String, existing: [MeetingSpeaker], channel: Channel) -> MeetingSpeaker {
        let keys = Set(existing.map(\.key))
        var number = 1
        while keys.contains("S\(number)") { number += 1 }
        let labels = Set(existing.map(\.label))
        var labelNumber = existing.filter { !$0.isMe }.count + 1
        while labels.contains(Strings.speakerLabel(labelNumber)) { labelNumber += 1 }
        return MeetingSpeaker(meetingId: meetingId, key: "S\(number)", label: Strings.speakerLabel(labelNumber), channel: channel)
    }

    /// Talk time, voice sample and embedding of every speaker of a meeting, from the lines they have now.
    /// Speakers without lines are removed.
    static func refreshSpeakers(_ db: Database, meetingId: String) throws {
        let lines = try Segment.filter(Column("meetingId") == meetingId).fetchAll(db)
        let byKey = Dictionary(grouping: lines, by: \.speakerKey)
        for var speaker in try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db) {
            guard let own = byKey[speaker.key], !own.isEmpty else {
                try speaker.delete(db)
                continue
            }
            speaker.talkTime = own.reduce(0) { $0 + $1.duration }
            if let longest = own.max(by: { $0.duration < $1.duration }) {
                speaker.sampleStart = longest.start
                speaker.sampleEnd = min(longest.end, longest.start + 12)
            }
            if let voice = SpeakerVoices.mainVoice(of: own) {
                speaker.embedding = voice.embeddingData
            }
            speaker.channel = own[0].channel
            try speaker.update(db)
        }
    }
}

// MARK: - The voices of one meeting

/// Which lines of each speaker of a meeting sound alike.
///
/// The diarizer sometimes puts two people into one speaker, and a microphone can pick up the call from the
/// speakers. Grouping a speaker's lines by voice shows that: one group is the speaker, a second one is
/// someone else, and each can be named on its own.
public enum SpeakerVoices {
    public struct Group: Identifiable, Equatable, Sendable {
        public var speakerKey: String
        public var index: Int
        public var segmentIds: [Int64]
        public var speech: Double
        public var centroid: [Float]
        /// The line to play and quote: the longest one.
        public var example: Segment

        public var id: String { "\(speakerKey)#\(index)" }
    }

    /// A group needs this much speech to be offered on its own, rather than counted as noise ("Ja.", "Genau.").
    public static let minimumSpeech: Double = 15
    /// And it must sound clearly unlike the speaker's main voice. Lines of one person in one meeting are
    /// about 0.7–0.9 alike to their main voice; another person's voice is below 0.4.
    public static let distinctBelow: Float = 0.5

    /// The groups of each speaker, biggest first. Speakers whose lines all sound alike have one group.
    public static func groups(of segments: [Segment]) -> [String: [Group]] {
        var result: [String: [Group]] = [:]
        for (key, lines) in Dictionary(grouping: segments, by: \.speakerKey) {
            result[key] = groups(ofSpeaker: key, lines: lines)
        }
        return result
    }

    static func groups(ofSpeaker key: String, lines: [Segment]) -> [Group] {
        let voiced = lines.filter { $0.embedding != nil && !$0.voiceIgnored && $0.id != nil }
        guard !voiced.isEmpty else { return [] }
        let vectors = voiced.map { [Float](embeddingData: $0.embedding!) }
        let durations = voiced.map(\.duration)
        let (indexGroups, _) = VoiceClustering.groups(vectors, durations: durations)
        let weights = durations.map { Float(min(max($0, 0.5), 20)) }
        return indexGroups.enumerated().compactMap { number, members in
            guard let example = members.map({ voiced[$0] }).max(by: { $0.duration < $1.duration }) else { return nil }
            return Group(
                speakerKey: key, index: number, segmentIds: members.compactMap { voiced[$0].id },
                speech: members.reduce(0) { $0 + durations[$1] },
                centroid: VoiceClustering.centroid(of: members, in: vectors, weights: weights), example: example
            )
        }
    }

    /// The groups worth showing on their own: besides the main one, those with real speech in them.
    public static func notable(_ groups: [Group]) -> [Group] {
        guard let main = groups.first, groups.count > 1 else { return [] }
        let others = groups.dropFirst().filter { $0.speech >= minimumSpeech && VoiceMath.cosine($0.centroid, main.centroid) < distinctBelow }
        return others.isEmpty ? [] : [main] + others
    }

    /// A speaker's voice: the centroid of their biggest group, so a few lines of someone else don't blur it.
    public static func mainVoice(of lines: [Segment]) -> [Float]? {
        groups(ofSpeaker: lines.first?.speakerKey ?? "", lines: lines).first?.centroid
    }
}
