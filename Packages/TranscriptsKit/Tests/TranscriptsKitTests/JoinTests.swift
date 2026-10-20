import Foundation
import Testing
@testable import TranscriptsKit

/// Meetings recorded one after another, joined into one ("Zusammenführen"): the audio one after another with a short
/// pause between, the lines, names, markers and tasks moved along, the later meetings gone.
///
/// In the suite of the other tests that move the app's folder (`AppPaths.overrideRoot`), so they never run at the
/// same time and nothing lands in the real one.
extension AudioArchiverTests {
    struct Parts {
        var first: Meeting
        var second: Meeting
        var third: Meeting
        var anna: Person
        var thomas: Person
        var ids: [String] { [first.id, second.id, third.id] }
    }

    /// 10:00 on a fixed day, plus `seconds`.
    func tenOClock(_ seconds: TimeInterval = 0, day: Int = 19) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 10))!.addingTimeInterval(seconds)
    }

    /// A meeting recorded here and processed: its audio kept compressed (no call file for `call` 0), its lines, its
    /// speakers (key, person, assignment).
    func recordedMeeting(_ database: AppDatabase, _ title: String, at start: Date, microphone: Double, call: Double,
                         lines: [(String, Channel, Double, Double, String)], speakers: [(String, String?, MeetingSpeaker.Assignment)]) throws -> Meeting {
        let meeting = Meeting(title: title, startedAt: start, duration: max(microphone, call), status: .ready, origin: .recording)
        try database.save(meeting)
        let segments = lines.map { Segment(meetingId: meeting.id, speakerKey: $0.0, channel: $0.1, start: $0.2, end: $0.3, text: $0.4) }
        try database.replaceTranscript(meetingId: meeting.id, segments: segments, speakers: speakers.map { key, personId, assignment in
            let own = segments.filter { $0.speakerKey == key }
            return MeetingSpeaker(meetingId: meeting.id, key: key, label: key == MeetingSpeaker.meKey ? Strings.meLabel : Strings.speakerLabel(Int(key.dropFirst()) ?? 1),
                                  personId: personId, assignment: assignment, confidence: assignment == .confirmed ? 1 : 0,
                                  talkTime: own.reduce(0) { $0 + $1.duration }, sampleStart: own.first?.start, sampleEnd: own.first?.end,
                                  channel: own.first?.channel ?? .system)
        })
        try writeTone(AppPaths.audioFile(for: meeting.id, channel: .microphone), seconds: microphone, frequency: 440, encoding: .aac)
        if call > 0 {
            try writeTone(AppPaths.audioFile(for: meeting.id, channel: .system), seconds: call, frequency: 660, encoding: .aac)
        }
        return meeting
    }

    /// The Weekly Sync recorded in three parts. The first: Anna and the user, four seconds (the call half a second
    /// shorter), a marker, a task. The second, a minute later: Anna again and Thomas, five seconds, a marker, a task
    /// done. The third, another minute later: only the microphone, the user and a voice without a name.
    func threeParts(_ database: AppDatabase) throws -> Parts {
        let anna = try database.person(named: "Anna Berger")
        let thomas = try database.person(named: "Thomas Klein")
        let me = try database.mePerson(defaultName: "Lukas")
        let first = try recordedMeeting(database, "Weekly Sync", at: tenOClock(), microphone: 4, call: 3.5, lines: [
            ("S1", .system, 0.5, 2.5, "Hallo, hier ist Anna."),
            (MeetingSpeaker.meKey, .microphone, 2.8, 3.6, "Hallo Anna."),
        ], speakers: [("S1", anna.id, .confirmed), (MeetingSpeaker.meKey, me.id, .confirmed)])
        _ = try database.addMarker(Marker(meetingId: first.id, time: 2, text: "Budget"))
        try writeTone(AppPaths.cleanedMicrophoneFile(for: first.id), seconds: 4, encoding: .aac)
        let second = try recordedMeeting(database, "Weekly Sync", at: tenOClock(64), microphone: 5, call: 5, lines: [
            ("S1", .system, 0.2, 2.4, "Und weiter, Anna hier."),
            ("S2", .system, 2.5, 4.8, "Thomas noch, kurz zum Budget."),
        ], speakers: [("S1", anna.id, .confirmed), ("S2", thomas.id, .confirmed)])
        _ = try database.addMarker(Marker(meetingId: second.id, time: 1, text: "Nachtrag"))
        let third = try recordedMeeting(database, "Weekly Sync", at: tenOClock(130), microphone: 2, call: 0, lines: [
            (MeetingSpeaker.meKey, .microphone, 0.3, 1.7, "Bis nächste Woche."),
            ("S1", .microphone, 1.7, 1.9, "Tschüss."),
        ], speakers: [(MeetingSpeaker.meKey, me.id, .confirmed), ("S1", nil, .unknown)])
        try database.writer.write { db in
            var task = ActionItem(meetingId: first.id, text: "Protokoll schicken", position: 0)
            try task.insert(db)
            var done = ActionItem(meetingId: second.id, text: "Folien teilen", done: true, position: 0)
            try done.insert(db)
        }
        return Parts(first: first, second: second, third: third, anna: anna, thomas: thomas)
    }

    @Test func joiningPutsTheLaterAudioAfterTheFirstWithAPauseBetween() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let parts = try threeParts(database)
            let id = parts.first.id

            try MeetingJoin.join(parts.ids, database: database, step: "Wartet")

            // 4 s (the longer channel), a pause of 2, 5 s, a pause of 2, 2 s.
            let microphoneFile = AppPaths.rawFile(for: id, channel: .microphone)
            let systemFile = AppPaths.rawFile(for: id, channel: .system)
            #expect(abs(SpeechAudio.duration(of: microphoneFile) - 15) < 0.2)
            #expect(abs(SpeechAudio.duration(of: systemFile) - SpeechAudio.duration(of: microphoneFile)) < 0.05)
            let microphone = try SpeechAudio.load(microphoneFile)
            let system = try SpeechAudio.load(systemFile)
            func level(_ samples: [Float], _ from: Double, _ to: Double) -> Float {
                SpeechAudio.rms(samples[SpeechAudio.samples(from)..<min(SpeechAudio.samples(to), samples.count)])
            }
            #expect(level(microphone, 0.5, 3.5) > 0.15)
            #expect(level(microphone, 4.2, 5.8) < 0.01, "the pause")
            #expect(level(microphone, 6.3, 10.7) > 0.15)
            #expect(level(microphone, 11.2, 12.8) < 0.01, "the pause")
            #expect(level(microphone, 13.2, 14.8) > 0.15)
            #expect(level(system, 1, 3) > 0.15)
            #expect(level(system, 3.65, 3.95) < 0.01, "the call padded to the microphone's length")
            #expect(level(system, 6.3, 10.7) > 0.15)
            #expect(level(system, 13.2, 14.8) < 0.01, "no call in the third part")

            // The first meeting's files are the joined ones now, to be compressed after the pass; the version without
            // echo covered only the first part; the later meetings' folders are gone.
            #expect(!FileManager.default.fileExists(atPath: AppPaths.audioFile(for: id, channel: .microphone).path))
            #expect(!FileManager.default.fileExists(atPath: AppPaths.cleanedMicrophoneFile(for: id).path))
            #expect(!FileManager.default.fileExists(atPath: MeetingJoin.joinedFile(for: id, channel: .microphone).path))
            #expect(!FileManager.default.fileExists(atPath: AppPaths.folder(for: parts.second.id).path))
            #expect(!FileManager.default.fileExists(atPath: AppPaths.folder(for: parts.third.id).path))
        }
    }

    @Test func joiningMovesTheLinesNamesMarkersAndTasksAlong() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let parts = try threeParts(database)

            try MeetingJoin.join(parts.ids, database: database, step: "Wartet")

            #expect(try database.meetingRows().map(\.id) == [parts.first.id])
            let detail = try #require(try database.detail(of: parts.first.id))
            #expect(abs(detail.meeting.duration - 15) < 0.2)
            #expect(detail.meeting.status == .processing)
            #expect(detail.meeting.processingStep == "Wartet")

            // The second part starts at 6 s, the third at 13 s.
            #expect(detail.segments.map(\.text) == ["Hallo, hier ist Anna.", "Hallo Anna.", "Und weiter, Anna hier.", "Thomas noch, kurz zum Budget.", "Bis nächste Woche.", "Tschüss."])
            let starts = detail.segments.map(\.start)
            for (start, expected) in zip(starts, [0.5, 2.8, 6.2, 8.5, 13.3, 14.7]) {
                #expect(abs(start - expected) < 0.2, "\(starts)")
            }
            // Anna is one voice, Thomas keeps his name, the user is there once, the voice without a name has a key and
            // a label of its own.
            let annas = detail.segments.filter { detail.speaker(for: $0.speakerKey)?.personId == parts.anna.id }
            #expect(annas.count == 2)
            #expect(Set(annas.map(\.speakerKey)).count == 1)
            let thomas = try #require(detail.speakers.first { $0.personId == parts.thomas.id })
            #expect(thomas.assignment == .confirmed)
            #expect(detail.segments.first { $0.text.hasPrefix("Thomas") }?.speakerKey == thomas.key)
            #expect(detail.speakers.filter(\.isMe).count == 1)
            let last = try #require(detail.segments.last)
            let unnamed = try #require(detail.speaker(for: last.speakerKey))
            #expect(unnamed.personId == nil)
            #expect(![annas[0].speakerKey, thomas.key, MeetingSpeaker.meKey].contains(unnamed.key))
            #expect(unnamed.label == Strings.speakerLabel(Int(unnamed.key.dropFirst()) ?? 0))

            #expect(detail.markers.map(\.text) == ["Budget", "Nachtrag"])
            #expect(abs((detail.markers.last?.time ?? 0) - 7) < 0.2)
            #expect(detail.actionItems.map(\.text) == ["Protokoll schicken", "Folien teilen"])
            #expect(detail.actionItems.map(\.done) == [false, true])
        }
    }

    /// The pass afterwards finds new voices in the joined audio; the names given in every part stay with their speech.
    @Test func theNamesOfEveryPartCarryOverToThePass() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let parts = try threeParts(database)
            try MeetingJoin.join(parts.ids, database: database, step: "Wartet")
            let detail = try #require(try database.detail(of: parts.first.id))

            func line(_ key: String, _ channel: Channel, _ start: Double, _ end: Double) -> DraftLine {
                DraftLine(speakerKey: key, channel: channel, start: start, end: end, words: [TimedWord(text: "…", start: start, end: end)])
            }
            var lines = [
                line("S1", .system, 0.5, 2.5), line(MeetingSpeaker.meKey, .microphone, 2.8, 3.6),
                line("S1", .system, 6.2, 8.4), line("S2", .system, 8.5, 10.8),
                line(MeetingSpeaker.meKey, .microphone, 13.3, 14.7),
            ]
            let carried = MeetingProcessor.carriedOver(from: detail, to: &lines)
            #expect(carried.assignments["S1"] == .some(parts.anna.id))
            #expect(carried.assignments["S2"] == .some(parts.thomas.id))
        }
    }

    @Test func meetingsThatChangedMeanwhileAreNotJoined() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let parts = try threeParts(database)
            // Transcribed again meanwhile.
            try database.update(meetingId: parts.second.id) { $0.status = .processing }

            #expect(throws: MeetingJoin.Failure.self) { try MeetingJoin.join(parts.ids, database: database, step: "Wartet") }

            #expect(try database.meetingRows().count == 3)
            #expect(try database.detail(of: parts.first.id)?.segments.count == 2)
            #expect(try database.detail(of: parts.first.id)?.meeting.status == .ready)
            #expect(abs(SpeechAudio.duration(of: AppPaths.audioFile(for: parts.first.id, channel: .microphone)) - 4) < 0.1)
            #expect(!FileManager.default.fileExists(atPath: MeetingJoin.joinedFile(for: parts.first.id, channel: .microphone).path))
            #expect(FileManager.default.fileExists(atPath: AppPaths.audioFile(for: parts.second.id, channel: .microphone).path))
        }
    }

    @Test func aJoinCutShortByAQuitIsFinishedOrUndoneOnTheNextLaunch() async throws {
        try await withFolder { _ in
            // Joined in the database (the meeting waits for its pass), the audio not yet in place.
            let joined = "joined-in-database"
            try writeTone(AppPaths.audioFile(for: joined, channel: .microphone), seconds: 3, encoding: .aac)
            try writeTone(MeetingJoin.joinedFile(for: joined, channel: .microphone), seconds: 8, encoding: .pcm)
            // Quit while the audio was written.
            let written = "audio-being-written"
            try writeTone(AppPaths.audioFile(for: written, channel: .microphone), seconds: 3, encoding: .aac)
            try writeTone(MeetingJoin.joinedFile(for: written, channel: .microphone), seconds: 5, encoding: .pcm)

            MeetingJoin.recover(interrupted: [joined])

            #expect(abs(SpeechAudio.duration(of: AppPaths.rawFile(for: joined, channel: .microphone)) - 8) < 0.05)
            #expect(!FileManager.default.fileExists(atPath: AppPaths.audioFile(for: joined, channel: .microphone).path))
            #expect(!FileManager.default.fileExists(atPath: MeetingJoin.joinedFile(for: joined, channel: .microphone).path))
            #expect(abs(SpeechAudio.duration(of: AppPaths.audioFile(for: written, channel: .microphone)) - 3) < 0.1)
            #expect(!FileManager.default.fileExists(atPath: MeetingJoin.joinedFile(for: written, channel: .microphone).path))
        }
    }

    @MainActor @Test func onlyFinishedMeetingsRecordedHereWithTheirAudioCanBeJoined() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let parts = try threeParts(database)
            let imported = Meeting(title: "Sprachmemo", startedAt: tenOClock(600), duration: 60, status: .ready, origin: .importedFile)
            try database.save(imported)
            try writeTone(AppPaths.audioFile(for: imported.id, channel: .microphone), seconds: 1, encoding: .aac)
            let yesterday = try recordedMeeting(database, "Gestern", at: tenOClock(day: 18), microphone: 1, call: 0, lines: [], speakers: [])
            let later = try recordedMeeting(database, "Am Nachmittag", at: tenOClock(5 * 3600), microphone: 1, call: 0, lines: [], speakers: [])
            let model = AppModel(database: database, settings: AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!), secrets: MemorySecretStore(), isDemo: true)
            model.rows = try database.meetingRows()

            // That day's meetings recorded here, in the order they were recorded; the parts are those close together.
            #expect(model.joinCandidates(for: parts.second.id).map(\.id) == parts.ids + [later.id])
            #expect(model.likelyParts(of: parts.second.id) == Set(parts.ids))
            #expect(model.likelyParts(of: later.id) == [later.id])
            #expect(model.joinCandidates(for: yesterday.id).isEmpty)
            #expect(model.joinCandidates(for: imported.id).isEmpty)

            var running = parts.third
            running.status = .recording
            #expect(!model.canJoin(running))
            AudioArchiver.deleteAudio(meetingId: parts.third.id)
            #expect(!model.canJoin(parts.third))
            #expect(model.joinCandidates(for: parts.first.id).map(\.id) == [parts.first.id, parts.second.id, later.id])
        }
    }
}

@Suite struct MeetingPartsTests {
    func meeting(_ id: String, at minutes: Double, for length: Double, event: String? = nil) -> Meeting {
        Meeting(id: id, title: id, startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + minutes * 60), duration: length * 60,
                status: .ready, calendarEventId: event)
    }

    @Test func thePartsOfAMeetingAreThoseRightBeforeAndAfterIt() {
        let first = meeting("10:00", at: 0, for: 12)
        let second = meeting("10:13", at: 13, for: 17)
        let third = meeting("10:31", at: 31, for: 9)
        let afternoon = meeting("14:00", at: 240, for: 60)
        let all = [afternoon, third, first, second]
        #expect(MeetingJoin.parts(of: second, among: all) == ["10:00", "10:13", "10:31"])
        #expect(MeetingJoin.parts(of: first, among: all) == ["10:00", "10:13", "10:31"])
        #expect(MeetingJoin.parts(of: afternoon, among: all) == ["14:00"])
    }

    @Test func meetingsOfDifferentCalendarEventsAreNotParts() {
        let standup = meeting("standup", at: 0, for: 15, event: "e-standup")
        let planning = meeting("planning", at: 15.5, for: 20, event: "e-planning")
        let rest = meeting("rest", at: 36, for: 5)
        #expect(MeetingJoin.parts(of: planning, among: [standup, planning, rest]) == ["planning", "rest"])
    }
}
