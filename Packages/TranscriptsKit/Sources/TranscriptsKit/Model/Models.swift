import Foundation
import GRDB

// MARK: - Meeting

/// One recorded or imported conversation.
public struct Meeting: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meeting"

    public enum Status: String, Codable, Sendable {
        /// Audio is still being captured.
        case recording
        /// Recorded, waiting for or running the full transcription pass.
        case processing
        /// Transcript, speakers and (if wanted) summary are done.
        case ready
        /// Processing stopped with an error; the audio is kept so it can be retried.
        case failed
    }

    public enum Origin: String, Codable, Sendable {
        case recording
        case importedFile
    }

    public var id: String
    public var title: String
    /// True once the user typed a title, so later steps (calendar, summary) leave it alone.
    public var titleIsCustom: Bool
    public var startedAt: Date
    public var duration: Double
    public var status: Status
    public var origin: Origin
    /// The app the call ran in ("Zoom", "Microsoft Teams"), when known.
    public var source: String?
    /// Detected language code of the transcript ("de", "en"), when known.
    public var language: String?
    public var calendarEventId: String?
    public var attendees: [Attendee]
    /// 0...1 while `status == .processing`.
    public var progress: Double
    public var processingStep: String?
    public var errorMessage: String?
    public var transcriptionModel: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        titleIsCustom: Bool = false,
        startedAt: Date = Date(),
        duration: Double = 0,
        status: Status = .recording,
        origin: Origin = .recording,
        source: String? = nil,
        language: String? = nil,
        calendarEventId: String? = nil,
        attendees: [Attendee] = [],
        progress: Double = 0,
        processingStep: String? = nil,
        errorMessage: String? = nil,
        transcriptionModel: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
        self.origin = origin
        self.source = source
        self.language = language
        self.calendarEventId = calendarEventId
        self.attendees = attendees
        self.progress = progress
        self.processingStep = processingStep
        self.errorMessage = errorMessage
        self.transcriptionModel = transcriptionModel
        self.createdAt = createdAt
    }

    public var endedAt: Date { startedAt.addingTimeInterval(duration) }
}

/// Someone invited to the calendar event a meeting belongs to.
public struct Attendee: Codable, Hashable, Sendable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

// MARK: - Transcript

/// Which recording a piece of speech came from.
public enum Channel: String, Codable, Sendable, CaseIterable {
    /// The local microphone: always the user, unless several people share the room.
    case microphone
    /// Everything the Mac played: the other participants of an online call.
    case system
}

/// One line of the transcript: a stretch of speech by one speaker.
public struct Segment: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "segment"

    public var id: Int64?
    public var meetingId: String
    /// Key of the `MeetingSpeaker` who said it ("me", "S1", "S2", …).
    public var speakerKey: String
    public var channel: Channel
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int64? = nil, meetingId: String, speakerKey: String, channel: Channel, start: Double, end: Double, text: String) {
        self.id = id
        self.meetingId = meetingId
        self.speakerKey = speakerKey
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A voice found in one meeting. Linked to a `Person` once known.
public struct MeetingSpeaker: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetingSpeaker"

    public enum Assignment: String, Codable, Sendable {
        /// Nobody known yet.
        case unknown
        /// The app proposes `suggestedPersonId` or `suggestedName`; waits for a click.
        case suggested
        /// Matched automatically with high confidence.
        case automatic
        /// Set or confirmed by the user.
        case confirmed
    }

    public static let meKey = "me"

    public var id: String { "\(meetingId)/\(key)" }
    public var meetingId: String
    public var key: String
    /// "Sprecher 2" — the label used while nobody is assigned.
    public var label: String
    public var personId: String?
    public var assignment: Assignment
    public var suggestedPersonId: String?
    /// A name heard in the conversation that does not belong to anyone known yet.
    public var suggestedName: String?
    /// Short explanation shown with a suggestion ("Miriam: „Gute Idee, Jonas.“").
    public var suggestionReason: String?
    /// Voice similarity behind the current suggestion or assignment, 0...1.
    public var confidence: Double
    /// Seconds of speech in this meeting.
    public var talkTime: Double
    /// L2-normalised voice embedding of this speaker in this meeting.
    public var embedding: Data?
    /// The longest clean stretch of this speaker, for "play a sample".
    public var sampleStart: Double?
    public var sampleEnd: Double?
    public var channel: Channel

    public init(
        meetingId: String,
        key: String,
        label: String,
        personId: String? = nil,
        assignment: Assignment = .unknown,
        suggestedPersonId: String? = nil,
        suggestedName: String? = nil,
        suggestionReason: String? = nil,
        confidence: Double = 0,
        talkTime: Double = 0,
        embedding: Data? = nil,
        sampleStart: Double? = nil,
        sampleEnd: Double? = nil,
        channel: Channel = .system
    ) {
        self.meetingId = meetingId
        self.key = key
        self.label = label
        self.personId = personId
        self.assignment = assignment
        self.suggestedPersonId = suggestedPersonId
        self.suggestedName = suggestedName
        self.suggestionReason = suggestionReason
        self.confidence = confidence
        self.talkTime = talkTime
        self.embedding = embedding
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.channel = channel
    }

    public var isMe: Bool { key == Self.meKey }
    public var needsReview: Bool { assignment == .suggested || (assignment == .unknown && !isMe) }
}

// MARK: - People and voices

public struct Person: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "person"

    public var id: String
    public var name: String
    public var email: String?
    /// The user of this Mac. Their voice comes from the microphone.
    public var isMe: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, email: String? = nil, isMe: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.email = email
        self.isMe = isMe
        self.createdAt = createdAt
    }

    public var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    public var firstName: String {
        String(name.split(separator: " ").first ?? Substring(name))
    }
}

/// One sample of a person's voice, kept to recognise them in later meetings.
public struct Voiceprint: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "voiceprint"

    public var id: String
    public var personId: String
    public var embedding: Data
    public var meetingId: String?
    /// Seconds of speech the embedding was taken from.
    public var duration: Double
    public var createdAt: Date

    public init(id: String = UUID().uuidString, personId: String, embedding: Data, meetingId: String?, duration: Double, createdAt: Date = Date()) {
        self.id = id
        self.personId = personId
        self.embedding = embedding
        self.meetingId = meetingId
        self.duration = duration
        self.createdAt = createdAt
    }
}

// MARK: - Summary

public struct MeetingSummary: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "summary"

    public var meetingId: String
    public var overview: String
    public var decisions: [String]
    public var openQuestions: [String]
    /// "Claude Opus 5.5", "qwen3:8b" — shown under the summary.
    public var model: String
    public var provider: String
    public var createdAt: Date

    public init(meetingId: String, overview: String, decisions: [String], openQuestions: [String], model: String, provider: String, createdAt: Date = Date()) {
        self.meetingId = meetingId
        self.overview = overview
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.model = model
        self.provider = provider
        self.createdAt = createdAt
    }
}

public struct ActionItem: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "actionItem"

    public var id: Int64?
    public var meetingId: String
    public var text: String
    public var owner: String?
    public var due: String?
    public var done: Bool
    public var position: Int

    public init(id: Int64? = nil, meetingId: String, text: String, owner: String? = nil, due: String? = nil, done: Bool = false, position: Int = 0) {
        self.id = id
        self.meetingId = meetingId
        self.text = text
        self.owner = owner
        self.due = due
        self.done = done
        self.position = position
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A moment the user flagged while recording, optionally with a note.
public struct Marker: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "marker"

    public var id: Int64?
    public var meetingId: String
    public var time: Double
    public var text: String

    public init(id: Int64? = nil, meetingId: String, time: Double, text: String) {
        self.id = id
        self.meetingId = meetingId
        self.time = time
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
