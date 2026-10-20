import Foundation
import GRDB

/// Meetings recorded one after another that are one meeting (recorded again after a stop by mistake, a false
/// warning or a crash), joined: the later ones' audio goes after the first one's, their lines, names, markers and
/// tasks with it, moved to where they now are, and the pass afterwards hears it all as one recording.
public enum MeetingJoin {
    /// The silence between two recordings in the joined audio. The real time between them (a restart, the minutes
    /// after a crash) is left out: nothing was recorded then, and a long silence would only be sat through when
    /// listening and transcribed for nothing. A short one stays, so the last words of one recording and the first of
    /// the next don't run into one line (`TranscriptAssembly.pauseBreaks` breaks lines at 1.2 s).
    public static let pause: TimeInterval = 2

    /// The gap up to which the meetings before and after one are taken for parts of it.
    static let partGap: TimeInterval = 10 * 60

    /// Where one of the meetings starts in the joined audio, in seconds.
    public struct Part: Equatable, Sendable {
        public var meetingId: String
        public var offset: TimeInterval
    }

    public enum Failure: LocalizedError {
        /// One of the meetings was deleted, recorded further or transcribed again meanwhile.
        case changed

        public var errorDescription: String? {
            String(localized: "Eines der Meetings hat sich inzwischen geändert.")
        }
    }

    /// The meetings that are parts of `meeting`: those right before and after it, and those before and after them,
    /// as long as no more than `partGap` lies between two and they don't belong to different calendar meetings.
    /// `candidates` are the meetings it can be joined with, `meeting` among them.
    static func parts(of meeting: Meeting, among candidates: [Meeting]) -> [String] {
        let sorted = candidates.sorted { $0.startedAt < $1.startedAt }
        guard let index = sorted.firstIndex(where: { $0.id == meeting.id }) else { return [] }
        func belong(_ earlier: Meeting, _ later: Meeting) -> Bool {
            if let one = earlier.calendarEventId, let other = later.calendarEventId, one != other { return false }
            return later.startedAt.timeIntervalSince(earlier.endedAt) <= partGap
        }
        var first = index, last = index
        while first > 0, belong(sorted[first - 1], sorted[first]) { first -= 1 }
        while last < sorted.count - 1, belong(sorted[last], sorted[last + 1]) { last += 1 }
        return sorted[first...last].map(\.id)
    }

    /// Joins the meetings, in the order they were recorded, in the first: the audio is written, the meetings are
    /// joined in the database, the audio takes its place and the later meetings' folders go. The first meeting then
    /// waits for its pass, with `step` as what it is doing. Returns where each meeting starts in the joined one.
    @discardableResult
    public static func join(_ meetingIds: [String], database: AppDatabase, step: String) throws -> [Part] {
        guard let first = meetingIds.first, meetingIds.count > 1 else { return [] }
        let audio = try writeAudio(of: meetingIds)
        do {
            try database.joinMeetings(audio.parts, duration: audio.duration, step: step)
        } catch {
            discardAudio(of: first)
            throw error
        }
        // Should the audio not go in place now, the next launch puts it there (see `recover`); the later meetings'
        // audio stays until then.
        try useJoinedAudio(of: first)
        for meetingId in meetingIds.dropFirst() {
            try? FileManager.default.removeItem(at: AppPaths.folder(for: meetingId))
        }
        return audio.parts
    }

    // MARK: Audio

    /// The joined audio, written next to the first meeting's own until it takes its place.
    static func joinedFile(for meetingId: String, channel: Channel) -> URL {
        AppPaths.folder(for: meetingId).appendingPathComponent(channel == .microphone ? "microphone-joined.caf" : "system-joined.caf")
    }

    /// Writes the meetings' audio one after another into recording files in the first one's folder: each channel,
    /// padded to the length of the longer one, then the pause. Returns where each meeting starts and the length of
    /// all. Reads a piece at a time: an hour of a meeting is never held at once.
    static func writeAudio(of meetingIds: [String]) throws -> (parts: [Part], duration: TimeInterval) {
        guard let first = meetingIds.first else { return ([], 0) }
        discardAudio(of: first)
        let channels = Channel.allCases.filter { channel in
            meetingIds.contains { AppPaths.existingAudio(for: $0, channel: channel) != nil }
        }
        var writers: [Channel: AudioFileWriter] = [:]
        // Closed before the files are used.
        defer { writers.values.forEach { $0.close() } }
        do {
            for channel in channels {
                writers[channel] = try AudioFileWriter(url: joinedFile(for: first, channel: channel))
            }
            var parts: [Part] = []
            var duration: TimeInterval = 0
            for (index, meetingId) in meetingIds.enumerated() {
                if index > 0 {
                    let pause = SpeechAudio.samples(Self.pause)
                    for writer in writers.values { try silence(pause, into: writer) }
                }
                parts.append(Part(meetingId: meetingId, offset: SpeechAudio.seconds(writers.values.map(\.samplesWritten).max() ?? 0)))
                var sources: [Channel: EarlierAudio.Source] = [:]
                for channel in channels {
                    if let url = AppPaths.existingAudio(for: meetingId, channel: channel) { sources[channel] = EarlierAudio.Source(url: url, setAside: false) }
                }
                duration = try EarlierAudio.copy(sources, into: writers)
            }
            return (parts, duration)
        } catch {
            writers.values.forEach { $0.close() }
            discardAudio(of: first)
            throw error
        }
    }

    private static func silence(_ count: Int, into writer: AudioFileWriter) throws {
        let chunk = SpeechAudio.samples(30)
        var left = count
        while left > 0 {
            try writer.write([Float](repeating: 0, count: min(chunk, left)))
            left -= chunk
        }
    }

    /// The meetings are joined in the database: the joined audio takes the place of the first one's, as recording
    /// files, which the pass afterwards compresses. Its microphone without echo covered only its own part.
    static func useJoinedAudio(of meetingId: String) throws {
        for channel in Channel.allCases {
            let joined = joinedFile(for: meetingId, channel: channel)
            guard FileManager.default.fileExists(atPath: joined.path) else { continue }
            try? FileManager.default.removeItem(at: AppPaths.audioFile(for: meetingId, channel: channel))
            let raw = AppPaths.rawFile(for: meetingId, channel: channel)
            try? FileManager.default.removeItem(at: raw)
            try FileManager.default.moveItem(at: joined, to: raw)
        }
        try? FileManager.default.removeItem(at: AppPaths.cleanedMicrophoneFile(for: meetingId))
    }

    /// The meetings weren't joined: the joined audio goes.
    static func discardAudio(of meetingId: String) {
        for channel in Channel.allCases {
            try? FileManager.default.removeItem(at: joinedFile(for: meetingId, channel: channel))
        }
    }

    /// At launch, after the app quit in the middle of joining: where the meetings were joined in the database (the
    /// meeting waits for its pass, in `interrupted`), the joined audio is put in place; where they weren't, it goes.
    static func recover(interrupted: Set<String>) {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.recordings.path)) ?? []
        for meetingId in folders where Channel.allCases.contains(where: { FileManager.default.fileExists(atPath: joinedFile(for: meetingId, channel: $0).path) }) {
            if interrupted.contains(meetingId) {
                try? useJoinedAudio(of: meetingId)
            } else {
                discardAudio(of: meetingId)
            }
        }
    }
}

extension AppDatabase {
    /// Joins the meetings of `parts` in the first: the later ones' lines, voices, markers and tasks move to it, each
    /// moved by where its meeting starts in the joined audio, and the later meetings are deleted. The first is then
    /// all of the meeting, `duration` long, and waits for its pass. Their voices keep their names, under keys of their
    /// own ("S1" of the second meeting may become "S4"); voices of one person become one.
    func joinMeetings(_ parts: [MeetingJoin.Part], duration: TimeInterval, step: String) throws {
        try writer.write { db in
            guard let firstPart = parts.first, var meeting = try Meeting.fetchOne(db, key: firstPart.meetingId) else { throw MeetingJoin.Failure.changed }
            var later: [(offset: TimeInterval, meeting: Meeting)] = []
            for part in parts.dropFirst() {
                guard let other = try Meeting.fetchOne(db, key: part.meetingId) else { throw MeetingJoin.Failure.changed }
                later.append((part.offset, other))
            }
            let finished: (Meeting) -> Bool = { $0.origin == .recording && ($0.status == .ready || $0.status == .failed) }
            guard finished(meeting), later.allSatisfy({ finished($0.meeting) }) else { throw MeetingJoin.Failure.changed }

            var used = Set(try String.fetchAll(db, sql: "SELECT key FROM meetingSpeaker WHERE meetingId = ?", arguments: [meeting.id]))
            used.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT speakerKey FROM segment WHERE meetingId = ?", arguments: [meeting.id]))
            var number = used.compactMap { $0.hasPrefix("S") ? Int($0.dropFirst()) : nil }.max() ?? 0
            var position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM actionItem WHERE meetingId = ?", arguments: [meeting.id]) ?? -1) + 1

            for (offset, other) in later {
                let speakers = try MeetingSpeaker.filter(Column("meetingId") == other.id).fetchAll(db)
                let lines = try Segment.filter(Column("meetingId") == other.id).fetchAll(db)
                // The user's voice is the same in every part; every other voice gets a key not used in the meeting.
                var keys = [MeetingSpeaker.meKey: MeetingSpeaker.meKey]
                for key in speakers.map(\.key) + lines.map(\.speakerKey) where keys[key] == nil {
                    repeat { number += 1 } while used.contains("S\(number)")
                    keys[key] = "S\(number)"
                    used.insert("S\(number)")
                }
                for speaker in speakers {
                    guard let key = keys[speaker.key] else { continue }
                    if speaker.isMe, try MeetingSpeaker.fetchOne(db, key: ["meetingId": meeting.id, "key": key]) != nil { continue }
                    var moved = speaker
                    moved.meetingId = meeting.id
                    moved.key = key
                    if !speaker.isMe, Strings.number(inLabel: speaker.label) != nil, let new = Int(key.dropFirst()) {
                        moved.label = Strings.speakerLabel(new)
                    }
                    moved.sampleStart = speaker.sampleStart.map { $0 + offset }
                    moved.sampleEnd = speaker.sampleEnd.map { $0 + offset }
                    try moved.insert(db)
                }
                for var line in lines {
                    line.meetingId = meeting.id
                    line.speakerKey = keys[line.speakerKey] ?? line.speakerKey
                    line.movedFromKey = line.movedFromKey.map { keys[$0] ?? $0 }
                    line.start += offset
                    line.end += offset
                    try line.update(db)
                }
                try db.execute(sql: "UPDATE marker SET meetingId = ?, time = time + ? WHERE meetingId = ?", arguments: [meeting.id, offset, other.id])
                for var item in try ActionItem.filter(Column("meetingId") == other.id).order(Column("position")).fetchAll(db) {
                    item.meetingId = meeting.id
                    item.position = position
                    position += 1
                    try item.update(db)
                }
                try db.execute(sql: "UPDATE voiceprint SET meetingId = ? WHERE meetingId = ?", arguments: [meeting.id, other.id])

                // What the first meeting doesn't know, a later one may: a title the user gave, the calendar event.
                if !meeting.titleIsCustom, other.titleIsCustom {
                    meeting.title = other.title
                    meeting.titleIsCustom = true
                }
                if meeting.calendarEventId == nil, other.calendarEventId != nil {
                    meeting.calendarEventId = other.calendarEventId
                    if !meeting.titleIsCustom { meeting.title = other.title }
                }
                if meeting.attendees.isEmpty { meeting.attendees = other.attendees }
                if meeting.source == nil { meeting.source = other.source }
                _ = try other.delete(db)
            }

            // Still finished here, so the voices of one person can become one (see `joinVoicesOfSamePerson`).
            try Self.joinVoicesOfSamePerson(db, meetingId: meeting.id)
            try Self.refreshSpeakers(db, meetingId: meeting.id)
            meeting.duration = duration
            meeting.status = .processing
            meeting.progress = 0
            meeting.processingStep = step
            meeting.errorMessage = nil
            try meeting.update(db)
        }
    }
}
