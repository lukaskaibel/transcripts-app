import Foundation
import GRDB

/// Keeps the voices of all meetings in step with what the app knows now.
///
/// After a name was confirmed or corrected, every voice the user has not settled is judged again: an
/// automatic name that no longer holds up becomes a suggestion or is dropped, and voices that now clearly
/// sound like someone get that name. So an early mistake is not carried along: once it is corrected,
/// everything that followed from it follows the correction. Confirmed voices are never touched, and
/// suggestions that come from a spoken name stay until the user decides.
public enum VoiceRecheck {
    /// Judges every unsettled voice again. Returns how many changed.
    @discardableResult
    public static func run(database: AppDatabase, library: VoiceLibrary, thresholds: VoiceThresholds) throws -> Int {
        let (meetings, speakers, people) = try database.reader.read { db in
            (
                try Meeting.filter(Column("status") == Meeting.Status.ready.rawValue).fetchAll(db),
                try MeetingSpeaker.filter(Column("assignment") != MeetingSpeaker.Assignment.confirmed.rawValue && Column("key") != MeetingSpeaker.meKey).fetchAll(db),
                try Person.fetchAll(db)
            )
        }
        let meetingsById = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })
        let me = people.first(where: \.isMe)?.id
        var changes: [(before: MeetingSpeaker, after: MeetingSpeaker)] = []
        for speaker in speakers {
            guard let data = speaker.embedding, let meeting = meetingsById[speaker.meetingId] else { continue }
            let identifier = SpeakerIdentifier(library: library, people: people, attendees: meeting.attendees, thresholds: thresholds) { $0 }
            let invited = Set(meeting.attendees.compactMap { identifier.person(for: $0)?.id })
            let matches = library.rank([Float](embeddingData: data), boosted: invited, excluding: me.map { [$0] } ?? [], excludingMeeting: meeting.id)
            let updated = rechecked(speaker, matches: matches, thresholds: thresholds)
            if updated != speaker { changes.append((speaker, updated)) }
        }
        guard !changes.isEmpty else { return 0 }
        return try database.writer.write { db in
            var written = 0
            for change in changes {
                // Only if nobody changed the voice in the meantime (the user may just have named it).
                guard try MeetingSpeaker.fetchOne(db, key: ["meetingId": change.before.meetingId, "key": change.before.key]) == change.before else { continue }
                try change.after.update(db)
                written += 1
            }
            return written
        }
    }

    /// One voice judged against the current matches.
    static func rechecked(_ speaker: MeetingSpeaker, matches: [VoiceMatch], thresholds: VoiceThresholds) -> MeetingSpeaker {
        let matches = matches.filter { !speaker.rejectedPersonIds.contains($0.personId) }
        let votedByVoice = speaker.assignment == .automatic || speaker.assignment == .unknown
            || (speaker.assignment == .suggested && SpeakerIdentifier.isVoiceReason(speaker.suggestionReason))
        guard votedByVoice else {
            // A name that was said stays the suggestion; the voice may still add who else it could be.
            guard speaker.assignment == .suggested else { return speaker }
            var result = speaker
            result.candidatePersonIds = VoiceLibrary.candidates(matches, thresholds: thresholds)
            return result
        }
        var result = speaker
        let best = matches.first
        let runnerUp = matches.dropFirst().first?.similarity ?? 0
        if let best, best.similarity >= thresholds.automatic, best.similarity - runnerUp >= thresholds.margin {
            result.assignment = .automatic
            result.personId = best.personId
            result.suggestedPersonId = nil
            result.suggestedName = nil
            result.suggestionReason = nil
            result.confidence = Double(min(best.similarity, 1))
            result.candidatePersonIds = []
        } else if let best, best.similarity >= thresholds.suggestion {
            result.assignment = .suggested
            result.personId = nil
            result.suggestedPersonId = best.personId
            result.suggestedName = nil
            result.suggestionReason = SpeakerIdentifier.voiceReason(best)
            result.confidence = Double(min(best.similarity, 1))
            result.candidatePersonIds = VoiceLibrary.candidates(matches, thresholds: thresholds)
        } else {
            result.assignment = .unknown
            result.personId = nil
            result.suggestedPersonId = nil
            result.suggestedName = nil
            result.suggestionReason = nil
            result.confidence = 0
            result.candidatePersonIds = VoiceLibrary.candidates(matches, thresholds: thresholds)
        }
        return result
    }

    // MARK: Lines in the wrong place

    /// A move the app would make: lines of one speaker that clearly sound like someone else.
    public struct Move: Equatable, Sendable {
        public var meetingId: String
        public var segmentIds: [Int64]
        public var fromKey: String
        public var personId: String
        public var similarity: Float
    }

    /// Moves lines that clearly belong to someone else to that person, in every meeting.
    ///
    /// The voice separation now and then gives a few lines of one person to another ("Hai" says three things
    /// in Julian's voice). Such a group of lines moves when it sounds as clearly like another person as an
    /// automatic name needs, clearly more than like the speaker it is with, and unlike that speaker's main
    /// voice. Lines the user placed stay; the user's own voice and microphone are left out. Moved lines only
    /// count as recognised speech, so a wrong move can't teach the app anything, and the user can send them
    /// back. Returns how many groups moved.
    @discardableResult
    public static func moveStrayLines(database: AppDatabase, library: VoiceLibrary, thresholds: VoiceThresholds) throws -> Int {
        let moves = try strayMoves(database: database, library: library, thresholds: thresholds)
        var moved = 0
        for move in moves {
            // Only if the lines are still where they were judged.
            let still = try database.reader.read { db in
                try Segment.filter(keys: move.segmentIds).fetchAll(db).allSatisfy { $0.speakerKey == move.fromKey && $0.placement != .user }
            }
            guard still else { continue }
            try database.moveLines(move.segmentIds, in: move.meetingId, toPerson: move.personId, byApp: true, confidence: Double(min(move.similarity, 1)))
            moved += 1
        }
        return moved
    }

    public static func strayMoves(database: AppDatabase, library: VoiceLibrary, thresholds: VoiceThresholds) throws -> [Move] {
        let (meetings, people) = try database.reader.read { db in
            (try Meeting.filter(Column("status") == Meeting.Status.ready.rawValue).fetchAll(db), try Person.fetchAll(db))
        }
        let me = people.first(where: \.isMe)?.id
        var moves: [Move] = []
        for meeting in meetings {
            guard let detail = try database.detail(of: meeting.id) else { continue }
            let placedByUser = Set(detail.segments.filter { $0.placement == .user }.compactMap(\.id))
            for (key, groups) in SpeakerVoices.groups(of: detail.segments) where key != MeetingSpeaker.meKey && groups.count > 1 {
                guard let speaker = detail.speaker(for: key), let main = groups.first else { continue }
                for group in groups.dropFirst() {
                    let ids = group.segmentIds.filter { !placedByUser.contains($0) }
                    let speech = detail.segments.filter { $0.id.map(ids.contains) ?? false }.reduce(0) { $0 + $1.duration }
                    guard speech >= 3, VoiceMath.cosine(group.centroid, main.centroid) < SpeakerVoices.distinctBelow else { continue }
                    let matches = library.rank(group.centroid, excluding: Set([me, speaker.personId].compactMap { $0 }), excludingMeeting: meeting.id)
                    guard let best = matches.first, best.similarity >= thresholds.automatic,
                          best.similarity - (matches.dropFirst().first?.similarity ?? 0) >= thresholds.margin else { continue }
                    let own = speaker.personId.flatMap { library.similarity(group.centroid, to: $0) } ?? 0
                    guard best.similarity - own >= thresholds.margin else { continue }
                    moves.append(Move(meetingId: meeting.id, segmentIds: ids, fromKey: key, personId: best.personId, similarity: best.similarity))
                }
            }
        }
        return moves
    }
}
