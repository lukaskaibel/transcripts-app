import Foundation
import GRDB

/// The app's SQLite database: meetings, transcripts, people and voices.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// The database in Application Support, created on first use.
    public static func openShared(at folder: URL = AppPaths.applicationSupport) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: folder.appendingPathComponent("transcripts.sqlite").path, configuration: config)
        return try AppDatabase(pool)
    }

    /// An empty in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    public var reader: any DatabaseReader { writer }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("titleIsCustom", .boolean).notNull().defaults(to: false)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("source", .text)
                t.column("language", .text)
                t.column("calendarEventId", .text)
                t.column("attendees", .jsonText).notNull().defaults(to: "[]")
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("processingStep", .text)
                t.column("errorMessage", .text)
                t.column("transcriptionModel", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("isMe", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "segment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().indexed().references("meeting", onDelete: .cascade)
                t.column("speakerKey", .text).notNull()
                t.column("channel", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(virtualTable: "segment_ft", using: FTS5()) { t in
                t.synchronize(withTable: "segment")
                t.tokenizer = .unicode61()
                t.column("text")
            }
            try db.create(table: "meetingSpeaker") { t in
                t.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.primaryKey(["meetingId", "key"])
                t.column("label", .text).notNull()
                t.column("personId", .text).indexed().references("person", onDelete: .setNull)
                t.column("assignment", .text).notNull()
                t.column("suggestedPersonId", .text).references("person", onDelete: .setNull)
                t.column("suggestedName", .text)
                t.column("suggestionReason", .text)
                t.column("confidence", .double).notNull().defaults(to: 0)
                t.column("talkTime", .double).notNull().defaults(to: 0)
                t.column("embedding", .blob)
                t.column("sampleStart", .double)
                t.column("sampleEnd", .double)
                t.column("channel", .text).notNull()
            }
            try db.create(table: "voiceprint") { t in
                t.primaryKey("id", .text)
                t.column("personId", .text).notNull().indexed().references("person", onDelete: .cascade)
                t.column("embedding", .blob).notNull()
                t.column("meetingId", .text).references("meeting", onDelete: .setNull)
                t.column("duration", .double).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "summary") { t in
                t.primaryKey("meetingId", .text).references("meeting", onDelete: .cascade)
                t.column("overview", .text).notNull()
                t.column("decisions", .jsonText).notNull()
                t.column("openQuestions", .jsonText).notNull()
                t.column("model", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "actionItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().indexed().references("meeting", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("owner", .text)
                t.column("due", .text)
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "marker") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().indexed().references("meeting", onDelete: .cascade)
                t.column("time", .double).notNull()
                t.column("text", .text).notNull()
            }
        }
        migrator.registerMigration("v2-line-voices") { db in
            try db.alter(table: "segment") { t in
                t.add(column: "embedding", .blob)
                t.add(column: "voiceIgnored", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "meetingSpeaker") { t in
                t.add(column: "rejectedPersonIds", .jsonText).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v3-voice-guesses") { db in
            try db.alter(table: "segment") { t in
                t.add(column: "placement", .text)
                t.add(column: "movedFromKey", .text)
            }
            try db.alter(table: "meetingSpeaker") { t in
                t.add(column: "candidatePersonIds", .jsonText).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v4-github") { db in
            try db.alter(table: "actionItem") { t in
                t.add(column: "issue", .jsonText)
            }
            try db.alter(table: "person") { t in
                t.add(column: "github", .jsonText)
            }
            try db.create(table: "githubRoute") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("key", .text).notNull()
                t.column("label", .text).notNull()
                t.column("members", .jsonText).notNull().defaults(to: "[]")
                t.column("target", .jsonText).notNull()
                t.column("targetKey", .text).notNull()
                t.column("count", .integer).notNull().defaults(to: 1)
                t.column("lastUsedAt", .datetime).notNull()
                t.uniqueKey(["kind", "key", "targetKey"])
            }
        }
        return migrator
    }
}

// MARK: - Reading

/// Everything the meeting screen shows, read in one transaction.
public struct MeetingDetail: Equatable, Sendable {
    public var meeting: Meeting
    public var segments: [Segment]
    public var speakers: [MeetingSpeaker]
    public var people: [String: Person]
    public var summary: MeetingSummary?
    public var actionItems: [ActionItem]
    public var markers: [Marker]

    public func speaker(for key: String) -> MeetingSpeaker? {
        speakers.first { $0.key == key }
    }

    /// The name shown for a speaker: the assigned person, "Du" for the microphone, whom the app guesses
    /// ("Hai?", "Hai oder Julian?"), or the label.
    public func displayName(for key: String) -> String {
        guard let speaker = speaker(for: key) else { return key == MeetingSpeaker.meKey ? Strings.me : key }
        if let personId = speaker.personId, let person = people[personId] { return person.name }
        if speaker.isMe { return Strings.me }
        if let guess = guessText(for: speaker) { return "\(guess)?" }
        return Strings.label(speaker.label)
    }

    /// The name for a summary or an export: like `displayName`, but a guess is spelled out so a reader (or a
    /// language model) can weigh it: "Sprecher 2 (vielleicht Hai oder Julian)".
    public func textName(for key: String) -> String {
        guard let speaker = speaker(for: key), speaker.personId == nil, !speaker.isMe, let guess = guessText(for: speaker) else {
            return displayName(for: key)
        }
        return String(localized: "\(Strings.label(speaker.label)) (vielleicht \(guess))")
    }

    /// The people a speaker may be, known to this detail.
    public func guesses(for speaker: MeetingSpeaker) -> [Person] {
        speaker.guesses.compactMap { people[$0] }
    }

    private func guessText(for speaker: MeetingSpeaker) -> String? {
        var names = guesses(for: speaker).map(\.name)
        if names.isEmpty, speaker.assignment == .suggested, let name = speaker.suggestedName { names = [name] }
        guard !names.isEmpty else { return nil }
        return Strings.alternatives(names)
    }
}

/// A meeting in the list, with what the row needs.
public struct MeetingRow: Equatable, Identifiable, Sendable {
    public var meeting: Meeting
    public var speakers: [MeetingSpeaker]
    public var hasSummary: Bool
    public var pendingVoices: Int
    /// When the summary was written, for "Neue Zusammenfassung" in the inbox.
    public var summaryCreatedAt: Date?
    /// The summary's first paragraph.
    public var summaryOverview: String?
    /// The summary's tasks, in their order.
    public var actionItems: [ActionItem]

    public var id: String { meeting.id }

    /// Open tasks that are on GitHub neither as a new nor as a linked issue.
    public var unsentTasks: Int { actionItems.filter { !$0.done && $0.issue == nil }.count }

    public init(meeting: Meeting, speakers: [MeetingSpeaker] = [], hasSummary: Bool = false, pendingVoices: Int = 0,
                summaryCreatedAt: Date? = nil, summaryOverview: String? = nil, actionItems: [ActionItem] = []) {
        self.meeting = meeting
        self.speakers = speakers
        self.hasSummary = hasSummary
        self.pendingVoices = pendingVoices
        self.summaryCreatedAt = summaryCreatedAt
        self.summaryOverview = summaryOverview
        self.actionItems = actionItems
    }
}

/// A transcript line that matched a search.
public struct SearchHit: Equatable, Identifiable, Sendable {
    public var segment: Segment
    public var meetingTitle: String
    public var meetingDate: Date
    public var snippet: String

    public var id: Int64 { segment.id ?? 0 }
}

extension AppDatabase {
    public func meetingRows() throws -> [MeetingRow] {
        try reader.read { db in try Self.fetchMeetingRows(db) }
    }

    static func fetchMeetingRows(_ db: Database) throws -> [MeetingRow] {
        let meetings = try Meeting.order(Column("startedAt").desc).fetchAll(db)
        let speakers = Dictionary(grouping: try MeetingSpeaker.fetchAll(db), by: \.meetingId)
        var summarized: [String: (written: Date, overview: String)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT meetingId, createdAt, overview FROM summary") {
            summarized[row["meetingId"]] = (row["createdAt"], row["overview"])
        }
        let items = Dictionary(grouping: try ActionItem.order(Column("position")).fetchAll(db), by: \.meetingId)
        return meetings.map { meeting in
            let list = (speakers[meeting.id] ?? []).sorted { $0.talkTime > $1.talkTime }
            return MeetingRow(
                meeting: meeting,
                speakers: list,
                hasSummary: summarized[meeting.id] != nil,
                pendingVoices: list.filter(\.needsReview).count,
                summaryCreatedAt: summarized[meeting.id]?.written,
                summaryOverview: summarized[meeting.id]?.overview,
                actionItems: items[meeting.id] ?? []
            )
        }
    }

    public func detail(of meetingId: String) throws -> MeetingDetail? {
        try reader.read { db in try Self.fetchDetail(db, meetingId: meetingId) }
    }

    static func fetchDetail(_ db: Database, meetingId: String) throws -> MeetingDetail? {
        guard let meeting = try Meeting.fetchOne(db, key: meetingId) else { return nil }
        let segments = try Segment.filter(Column("meetingId") == meetingId).order(Column("start")).fetchAll(db)
        let speakers = try MeetingSpeaker.filter(Column("meetingId") == meetingId).order(Column("key")).fetchAll(db)
        let personIds = Set(speakers.flatMap { [$0.personId, $0.suggestedPersonId].compactMap { $0 } + $0.candidatePersonIds })
        let people = try Person.filter(keys: Array(personIds)).fetchAll(db)
        let summary = try MeetingSummary.fetchOne(db, key: meetingId)
        let items = try ActionItem.filter(Column("meetingId") == meetingId).order(Column("position")).fetchAll(db)
        let markers = try Marker.filter(Column("meetingId") == meetingId).order(Column("time")).fetchAll(db)
        return MeetingDetail(
            meeting: meeting,
            segments: segments,
            speakers: speakers,
            people: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }),
            summary: summary,
            actionItems: items,
            markers: markers
        )
    }

    public func people() throws -> [Person] {
        try reader.read { db in try Person.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    public func voiceprints() throws -> [Voiceprint] {
        try reader.read { db in try Voiceprint.fetchAll(db) }
    }

    /// Full-text search over all transcripts, newest meetings first.
    public func search(_ text: String, limit: Int = 30) throws -> [SearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT segment.*, meeting.title AS meetingTitle, meeting.startedAt AS meetingDate,
                       snippet(segment_ft, 0, '«', '»', '…', 12) AS snippet
                FROM segment
                JOIN segment_ft ON segment_ft.rowid = segment.id AND segment_ft MATCH ?
                JOIN meeting ON meeting.id = segment.meetingId
                ORDER BY meeting.startedAt DESC, segment.start
                LIMIT ?
                """, arguments: [pattern, limit])
            return try rows.map { row in
                SearchHit(
                    segment: try Segment(row: row),
                    meetingTitle: row["meetingTitle"],
                    meetingDate: row["meetingDate"],
                    snippet: row["snippet"]
                )
            }
        }
    }
}

// MARK: - Writing

extension AppDatabase {
    public func save(_ meeting: Meeting) throws {
        try writer.write { db in try meeting.save(db) }
    }

    public func update(meetingId: String, _ change: @escaping @Sendable (inout Meeting) -> Void) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return }
            change(&meeting)
            try meeting.update(db)
        }
    }

    public func deleteMeeting(_ meetingId: String) throws {
        _ = try writer.write { db in try Meeting.deleteOne(db, key: meetingId) }
    }

    /// Replaces a meeting's transcript and speakers in one go (after the full transcription pass).
    public func replaceTranscript(meetingId: String, segments: [Segment], speakers: [MeetingSpeaker]) throws {
        try writer.write { db in
            try Segment.filter(Column("meetingId") == meetingId).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).deleteAll(db)
            for var segment in segments { try segment.insert(db) }
            for speaker in speakers { try speaker.insert(db) }
        }
    }

    public func appendSegment(_ segment: Segment) throws -> Segment {
        try writer.write { db in
            var segment = segment
            try segment.insert(db)
            return segment
        }
    }

    public func save(_ speaker: MeetingSpeaker) throws {
        try writer.write { db in try speaker.save(db) }
    }

    public func save(_ person: Person) throws {
        try writer.write { db in try person.save(db) }
    }

    public func save(_ voiceprint: Voiceprint) throws {
        try writer.write { db in try voiceprint.save(db) }
    }

    public func deletePerson(_ personId: String) throws {
        try writer.write { db in
            // Speakers that were this person go back to unknown rather than keeping a dangling name.
            try db.execute(sql: "UPDATE meetingSpeaker SET assignment = 'unknown', confidence = 0 WHERE personId = ?", arguments: [personId])
            _ = try Person.deleteOne(db, key: personId)
        }
    }

    /// Moves everything of `source` over to `target` and deletes `source`.
    public func mergePerson(_ sourceId: String, into targetId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE meetingSpeaker SET personId = ? WHERE personId = ?", arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE meetingSpeaker SET suggestedPersonId = ? WHERE suggestedPersonId = ?", arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE voiceprint SET personId = ? WHERE personId = ?", arguments: [targetId, sourceId])
            try db.execute(sql: "UPDATE person SET github = COALESCE(github, (SELECT github FROM person WHERE id = ?)) WHERE id = ?", arguments: [sourceId, targetId])
            _ = try Person.deleteOne(db, key: sourceId)
        }
    }

    public func deleteVoiceprints(of personId: String) throws {
        _ = try writer.write { db in try Voiceprint.filter(Column("personId") == personId).deleteAll(db) }
    }

    public func save(summary: MeetingSummary, actionItems: [ActionItem]) throws {
        try writer.write { db in
            try summary.save(db)
            // Tasks already on GitHub keep their issue: a new summary that names the same task again takes the link
            // over, and the others stay at the end of the list.
            var linked = try ActionItem.filter(Column("meetingId") == summary.meetingId && Column("issue") != nil).order(Column("position")).fetchAll(db)
            try ActionItem.filter(Column("meetingId") == summary.meetingId).deleteAll(db)
            var items: [ActionItem] = []
            for item in actionItems {
                var item = item
                item.id = nil
                if item.issue == nil, let match = linked.indices.max(by: { IssueMatching.similarity(linked[$0].text, item.text) < IssueMatching.similarity(linked[$1].text, item.text) }),
                   IssueMatching.similarity(linked[match].text, item.text) >= 0.6 {
                    item.issue = linked[match].issue
                    item.done = item.done || linked[match].done
                    linked.remove(at: match)
                }
                items.append(item)
            }
            for old in linked {
                var old = old
                old.id = nil
                items.append(old)
            }
            for (index, item) in items.enumerated() {
                var item = item
                item.position = index
                try item.insert(db)
            }
        }
    }

    public func deleteSummary(of meetingId: String) throws {
        try writer.write { db in
            _ = try MeetingSummary.deleteOne(db, key: meetingId)
            try ActionItem.filter(Column("meetingId") == meetingId).deleteAll(db)
        }
    }

    public func setActionItem(_ id: Int64, done: Bool) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE actionItem SET done = ? WHERE id = ?", arguments: [done, id])
        }
    }

    public func addMarker(_ marker: Marker) throws -> Marker {
        try writer.write { db in
            var marker = marker
            try marker.insert(db)
            return marker
        }
    }

    public func deleteMarker(_ id: Int64) throws {
        _ = try writer.write { db in try Marker.deleteOne(db, key: id) }
    }

    /// The person record for the user, created on first use.
    public func mePerson(defaultName: String) throws -> Person {
        try writer.write { db in
            if let me = try Person.filter(Column("isMe") == true).fetchOne(db) { return me }
            let me = Person(name: defaultName, isMe: true)
            try me.insert(db)
            return me
        }
    }
}

// MARK: - Embedding storage

extension Array where Element == Float {
    /// Packs the floats as raw little-endian bytes for a BLOB column.
    public var embeddingData: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public init(embeddingData data: Data) {
        let count = data.count / MemoryLayout<Float>.size
        self = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            _ = data.copyBytes(to: buffer)
            initialized = count
        }
    }
}
