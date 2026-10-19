import Foundation
import Testing
@testable import TranscriptsKit

/// Recording more of a stopped meeting ("Weiter aufnehmen"): the earlier audio first in the new files, the live
/// transcript going on from the old one, and a pass over the old part that must not overwrite the new.
///
/// In the suite of the other tests that move the app's folder (`AppPaths.overrideRoot`), so they never run at the
/// same time and nothing lands in the real one.
extension AudioArchiverTests {
    /// A tone of `seconds`, written to `url` (CAF while recording, M4A as kept after processing).
    func writeTone(_ url: URL, seconds: Double, frequency: Float = 440, encoding: AudioFileWriter.Encoding) throws {
        let count = SpeechAudio.samples(seconds)
        let writer = try AudioFileWriter(url: url, encoding: encoding)
        try writer.write((0..<count).map { 0.3 * sin(2 * .pi * frequency * Float($0) / Float(SpeechAudio.sampleRate)) })
        writer.close()
    }

    func withFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
        defer {
            AppPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try await body(root)
    }

    /// A source that plays `seconds` of tone (or silence) quickly, and says when it is through.
    func source(_ root: URL, seconds: Double, silent: Bool = false) throws -> FileAudioSource {
        let url = root.appendingPathComponent("source-\(UUID().uuidString).caf")
        if silent {
            let writer = try AudioFileWriter(url: url)
            try writer.write([Float](repeating: 0, count: SpeechAudio.samples(seconds)))
            writer.close()
        } else {
            try writeTone(url, seconds: seconds, frequency: 330, encoding: .pcm)
        }
        return try FileAudioSource(url: url, speed: 8)
    }

    func played(_ sources: [FileAudioSource], by session: RecordingSession) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    await withCheckedContinuation { continuation in source.onFinished = { continuation.resume() } }
                }
            }
            try await session.start()
            try await group.waitForAll()
        }
    }

    /// Anna and the user talked for four seconds, Anna's voice named for good, a marker set.
    func processedMeeting(_ database: AppDatabase, root: URL) throws -> (MeetingDetail, Person) {
        let anna = try database.person(named: "Anna Berger")
        let me = try database.mePerson(defaultName: "Lukas")
        let meeting = Meeting(title: "Weekly", startedAt: Date().addingTimeInterval(-600), duration: 4, status: .ready, origin: .recording)
        try database.save(meeting)
        var voice = [Float](repeating: 0, count: 256)
        voice[3] = 1
        try database.replaceTranscript(meetingId: meeting.id, segments: [
            Segment(meetingId: meeting.id, speakerKey: "S1", channel: .system, start: 0.5, end: 2.5, text: "Hallo, hier ist Anna."),
            Segment(meetingId: meeting.id, speakerKey: MeetingSpeaker.meKey, channel: .microphone, start: 2.8, end: 3.6, text: "Hallo Anna."),
        ], speakers: [
            MeetingSpeaker(meetingId: meeting.id, key: "S1", label: "Sprecher 1", personId: anna.id, assignment: .confirmed, confidence: 1, talkTime: 2, embedding: voice.embeddingData, channel: .system),
            MeetingSpeaker(meetingId: meeting.id, key: MeetingSpeaker.meKey, label: Strings.meLabel, personId: me.id, assignment: .confirmed, confidence: 1, talkTime: 0.8, channel: .microphone),
        ])
        _ = try database.addMarker(Marker(meetingId: meeting.id, time: 2, text: "Budget"))
        try writeTone(AppPaths.audioFile(for: meeting.id, channel: .microphone), seconds: 4, encoding: .aac)
        try writeTone(AppPaths.audioFile(for: meeting.id, channel: .system), seconds: 3.5, frequency: 660, encoding: .aac)
        try writeTone(AppPaths.cleanedMicrophoneFile(for: meeting.id), seconds: 4, encoding: .aac)
        return (try #require(try database.detail(of: meeting.id)), anna)
    }

    @MainActor @Test func resumingPutsTheEarlierAudioFirstAndGoesOnFromTheTranscript() async throws {
        try await withFolder { root in
            let database = try AppDatabase.inMemory()
            let (previous, anna) = try processedMeeting(database, root: root)
            let id = previous.meeting.id
            let microphone = try source(root, seconds: 2)
            let system = try source(root, seconds: 2)
            let session = RecordingSession(meeting: previous.meeting, database: database, engine: SpeechEngine(), configuration: .init(),
                                           sources: [.microphone: microphone, .system: system], continuing: previous)
            // The live transcript shows what was said before, with the names known.
            #expect(session.lines.map(\.text) == ["Hallo, hier ist Anna.", "Hallo Anna."])
            #expect(session.markers.map(\.text) == ["Budget"])
            #expect(session.displayName(for: "S1") == "Anna Berger")

            try await played([microphone, system], by: session)

            #expect(abs(session.offset - 4) < 0.1, "starts at \(session.offset) s")
            #expect(session.elapsed >= session.offset)
            // The version without echo covered only the part before.
            #expect(!FileManager.default.fileExists(atPath: AppPaths.cleanedMicrophoneFile(for: id).path))
            // A new voice of the call: not Anna's key (her name would carry over to it), and the time goes on.
            var voice = [Float](repeating: 0, count: 256)
            voice[9] = 1
            session.handle(.final(channel: .system, start: 0.5, end: 1.8, text: "Und weiter geht's.", speaker: nil, embedding: voice, voice: nil))
            let line = try #require(session.lines.last)
            #expect(line.text == "Und weiter geht's.")
            #expect(abs(line.start - (session.offset + 0.5)) < 0.01)
            #expect(line.speakerKey == "S2")
            #expect(session.voices["S2"]?.label == "Sprecher 2")

            await session.stop()
            #expect(session.systemAudioHeard)

            // Both files: what was before, the call's padded to the microphone's length, then the new part.
            let microphoneFile = AppPaths.rawFile(for: id, channel: .microphone)
            let systemFile = AppPaths.rawFile(for: id, channel: .system)
            #expect(abs(SpeechAudio.duration(of: microphoneFile) - 6) < 0.15)
            #expect(abs(SpeechAudio.duration(of: systemFile) - SpeechAudio.duration(of: microphoneFile)) < 0.05)
            let samples = try SpeechAudio.load(systemFile)
            #expect(SpeechAudio.rms(samples[SpeechAudio.samples(1)..<SpeechAudio.samples(3)]) > 0.15)
            #expect(SpeechAudio.rms(samples[SpeechAudio.samples(3.6)..<SpeechAudio.samples(3.95)]) < 0.01)
            #expect(SpeechAudio.rms(samples[SpeechAudio.samples(4.3)..<SpeechAudio.samples(5.7)]) > 0.15)
            #expect(!FileManager.default.fileExists(atPath: EarlierAudio.setAsideFile(for: id, channel: .microphone).path))

            // In the database: the old lines and the new one, Anna still confirmed on her own key, the length of all.
            let detail = try #require(try database.detail(of: id))
            #expect(detail.segments.map(\.text) == ["Hallo, hier ist Anna.", "Hallo Anna.", "Und weiter geht's."])
            #expect(detail.speaker(for: "S1")?.personId == anna.id)
            #expect(detail.speaker(for: "S1")?.assignment == .confirmed)
            #expect(abs(detail.meeting.duration - 6) < 0.15)
            #expect(detail.meeting.status == .processing)
        }
    }

    @MainActor @Test func resumingBeforeThePassUsesTheRecordingFiles() async throws {
        try await withFolder { root in
            let database = try AppDatabase.inMemory()
            let meeting = Meeting(title: "Gerade beendet", duration: 3, status: .processing, origin: .recording)
            try database.save(meeting)
            try writeTone(AppPaths.rawFile(for: meeting.id, channel: .microphone), seconds: 3, encoding: .pcm)
            let previous = try #require(try database.detail(of: meeting.id))
            let microphone = try source(root, seconds: 2)
            let session = RecordingSession(meeting: meeting, database: database, engine: SpeechEngine(), configuration: .init(),
                                           sources: [.microphone: microphone], continuing: previous)

            try await played([microphone], by: session)
            await session.stop()

            #expect(abs(session.offset - 3) < 0.01)
            #expect(abs(SpeechAudio.duration(of: AppPaths.rawFile(for: meeting.id, channel: .microphone)) - 5) < 0.15)
            #expect(!FileManager.default.fileExists(atPath: EarlierAudio.setAsideFile(for: meeting.id, channel: .microphone).path))
        }
    }

    /// A microphone that can't start.
    final class BrokenMicrophone: AudioSource {
        var onSamples: (([Float]) -> Void)?
        func start() throws { throw AudioError.noInputDevice }
        func stop() {}
    }

    @MainActor @Test func aResumedRecordingThatCannotStartKeepsWhatWasRecorded() async throws {
        try await withFolder { _ in
            let database = try AppDatabase.inMemory()
            let meeting = Meeting(title: "Gerade beendet", duration: 3, status: .processing, origin: .recording)
            try database.save(meeting)
            try writeTone(AppPaths.rawFile(for: meeting.id, channel: .microphone), seconds: 3, encoding: .pcm)
            let previous = try #require(try database.detail(of: meeting.id))
            let session = RecordingSession(meeting: meeting, database: database, engine: SpeechEngine(), configuration: .init(),
                                           sources: [.microphone: BrokenMicrophone()], continuing: previous)

            await #expect(throws: AudioError.self) { try await session.start() }

            let samples = try SpeechAudio.load(AppPaths.rawFile(for: meeting.id, channel: .microphone))
            #expect(abs(SpeechAudio.seconds(samples.count) - 3) < 0.05)
            #expect(SpeechAudio.rms(samples) > 0.15)
        }
    }

    @Test func aCopyCutShortByAQuitIsUndoneOnTheNextLaunch() async throws {
        try await withFolder { _ in
            let id = "copy-cut-short"
            try writeTone(EarlierAudio.setAsideFile(for: id, channel: .microphone), seconds: 3, encoding: .pcm)
            try writeTone(AppPaths.rawFile(for: id, channel: .microphone), seconds: 1, encoding: .pcm)

            EarlierAudio.recover(meetingId: id)

            #expect(abs(SpeechAudio.duration(of: AppPaths.rawFile(for: id, channel: .microphone)) - 3) < 0.05)
            #expect(!FileManager.default.fileExists(atPath: EarlierAudio.setAsideFile(for: id, channel: .microphone).path))
        }
    }

    @MainActor @Test func silenceFromTheCallIsNotSoundHeard() async throws {
        try await withFolder { root in
            let database = try AppDatabase.inMemory()
            let meeting = Meeting(title: "Warten auf alle", status: .recording)
            try database.save(meeting)
            let microphone = try source(root, seconds: 1)
            let system = try source(root, seconds: 1, silent: true)
            let session = RecordingSession(meeting: meeting, database: database, engine: SpeechEngine(), configuration: .init(),
                                           sources: [.microphone: microphone, .system: system])
            try await played([microphone, system], by: session)
            await session.stop()
            #expect(!session.systemAudioHeard)
        }
    }

    @MainActor @Test func onlyAMeetingRecordedHereWithItsAudioCanBeRecordedFurther() async throws {
        try await withFolder { root in
            let database = try AppDatabase.inMemory()
            let model = AppModel(database: database, settings: AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!), secrets: MemorySecretStore(), isDemo: true)
            let (previous, _) = try processedMeeting(database, root: root)
            #expect(model.canResume(previous.meeting))

            var imported = previous.meeting
            imported.origin = .importedFile
            #expect(!model.canResume(imported))
            var running = previous.meeting
            running.status = .recording
            #expect(!model.canResume(running))

            AudioArchiver.deleteAudio(meetingId: previous.meeting.id)
            #expect(!model.canResume(previous.meeting))
        }
    }
}

/// The pass over a meeting that is recorded further meanwhile.
@Suite struct ProcessedTranscriptTests {
    @Test func aPassSavesNothingOverAMeetingThatIsRecordedAgain() throws {
        let database = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Weekly", status: .recording)
        try database.save(meeting)
        _ = try database.appendSegment(Segment(meetingId: meeting.id, speakerKey: MeetingSpeaker.meKey, channel: .microphone, start: 10, end: 12, text: "Live"))
        let old = [Segment(meetingId: meeting.id, speakerKey: "S1", channel: .system, start: 0, end: 4, text: "Alt")]

        #expect(try !database.replaceProcessedTranscript(meetingId: meeting.id, segments: old, speakers: []) { $0.status = .ready })
        let kept = try #require(try database.detail(of: meeting.id))
        #expect(kept.segments.map(\.text) == ["Live"])
        #expect(kept.meeting.status == .recording)

        try database.update(meetingId: meeting.id) { $0.status = .processing }
        #expect(try database.replaceProcessedTranscript(meetingId: meeting.id, segments: old, speakers: []) { $0.status = .ready })
        let saved = try #require(try database.detail(of: meeting.id))
        #expect(saved.segments.map(\.text) == ["Alt"])
        #expect(saved.meeting.status == .ready)
    }

    @Test func callAudioSeemsBlockedLaterWhereItCameThroughBefore() {
        #expect(!RecordingSession.callSeemsBlocked(silentSeconds: 15, workedBefore: false))
        #expect(RecordingSession.callSeemsBlocked(silentSeconds: 20, workedBefore: false))
        // Everyone in the call waiting for the meeting to begin.
        #expect(!RecordingSession.callSeemsBlocked(silentSeconds: 60, workedBefore: true))
        #expect(RecordingSession.callSeemsBlocked(silentSeconds: 90, workedBefore: true))
    }
}
