import AVFoundation
import Foundation
import NaturalLanguage

/// The full pass over a finished recording: transcribe both channels with the large model, separate
/// the voices, name them, and save the result. Replaces the live transcript.
public final class MeetingProcessor: @unchecked Sendable {
    public struct Options: Sendable {
        public var model: TranscriptionModel
        public var thresholds: VoiceThresholds
        /// Add confidently recognised voices to the library, so people are recognised better over time.
        public var learnVoices: Bool
        /// The name used for the user before they set one.
        public var defaultMyName: String

        public init(model: TranscriptionModel = .ultra, thresholds: VoiceThresholds = .standard, learnVoices: Bool = true, defaultMyName: String = "Ich") {
            self.model = model
            self.thresholds = thresholds
            self.learnVoices = learnVoices
            self.defaultMyName = defaultMyName
        }
    }

    public typealias Progress = @Sendable (_ step: String, _ fraction: Double) -> Void

    let database: AppDatabase
    let engine: SpeechEngine

    /// Voices this similar to an existing sample add nothing new to the library.
    static let redundantSimilarity: Float = 0.93
    static let maxVoiceprintsPerPerson = 15

    public init(database: AppDatabase, engine: SpeechEngine = .shared) {
        self.database = database
        self.engine = engine
    }

    public func process(meetingId: String, options: Options, progress: Progress? = nil) async throws {
        let report: Progress = { [database] step, fraction in
            try? database.update(meetingId: meetingId) { meeting in
                meeting.processingStep = step
                meeting.progress = fraction
            }
            progress?(step, fraction)
        }
        try database.update(meetingId: meetingId) { meeting in
            meeting.status = .processing
            meeting.errorMessage = nil
        }
        do {
            try await run(meetingId: meetingId, options: options, report: report)
        } catch {
            try? database.update(meetingId: meetingId) { meeting in
                meeting.status = .failed
                meeting.errorMessage = error.localizedDescription
                meeting.processingStep = nil
            }
            throw error
        }
    }

    private func run(meetingId: String, options: Options, report: @escaping Progress) async throws {
        report("Modelle werden geladen", 0.01)
        try await engine.prepare(model: options.model) { state in
            if case .preparing(let step, let fraction) = state {
                report("\(step) wird geladen", 0.01 + fraction * 0.04)
            }
        }
        guard let meeting = try await database.reader.read({ try Meeting.fetchOne($0, key: meetingId) }) else { return }

        report("Audio wird gelesen", 0.06)
        let importURL = AppPaths.existingImport(for: meetingId)
        let microphone = try AppPaths.existingAudio(for: meetingId, channel: .microphone).map(SpeechAudio.load) ?? []
        let system = try AppPaths.existingAudio(for: meetingId, channel: .system).map(SpeechAudio.load) ?? []
        let imported = try importURL.map(SpeechAudio.load) ?? []
        let duration = SpeechAudio.seconds(max(microphone.count, system.count, imported.count))

        let people = try database.people()
        let me = try database.mePerson(defaultName: options.defaultMyName)
        var library = VoiceLibrary(voiceprints: try database.voiceprints())

        var lines: [DraftLine] = []
        var audioByChannel: [Channel: [Float]] = [:]
        var micLearnable = false

        if !imported.isEmpty {
            audioByChannel[.microphone] = imported
            lines = try await room(imported, channel: .microphone, meStart: 0.1, library: library, people: people, thresholds: options.thresholds, report: report)
        } else {
            report("Sprache wird gesucht", 0.08)
            let systemSpeech = try await speechSeconds(system)
            let microphoneSpeech = try await speechSeconds(microphone)
            audioByChannel[.microphone] = microphone
            audioByChannel[.system] = system
            if systemSpeech >= 3 {
                report("Gesprächspartner werden transkribiert", 0.12)
                let systemText = try await engine.transcribe(system)
                report("Stimmen werden getrennt", 0.4)
                let diarization = try await engine.diarize(system) { fraction in report("Stimmen werden getrennt", 0.4 + fraction * 0.25) }
                let turns = try await refined(diarization.turns, words: systemText.words, audio: system, library: library, people: people, thresholds: options.thresholds, excluding: [me.id])
                let speakers = TranscriptAssembly.speakers(for: systemText.words, turns: turns)
                let breaks = TranscriptAssembly.pauseBreaks(words: systemText.words, turns: turns)
                let systemLines = TranscriptAssembly.renumbered(TranscriptAssembly.lines(words: systemText.words, speakers: speakers, channel: .system, breaks: breaks)).lines
                var microphoneLines: [DraftLine] = []
                if microphoneSpeech >= 0.5 {
                    report("Deine Spur wird transkribiert", 0.67)
                    let microphoneText = try await engine.transcribe(microphone)
                    let all = TranscriptAssembly.lines(
                        words: microphoneText.words,
                        speakers: microphoneText.words.map { _ in MeetingSpeaker.meKey },
                        channel: .microphone
                    )
                    microphoneLines = TranscriptAssembly.removeEchoes(microphone: all, system: systemLines)
                    micLearnable = microphoneLines.reduce(0) { $0 + $1.duration } >= 10
                }
                lines = TranscriptAssembly.merged(systemLines, microphoneLines)
            } else if microphoneSpeech >= 0.5 {
                // No call audio: a meeting in the room, everyone on the microphone.
                lines = try await room(microphone, channel: .microphone, meStart: 0.12, library: library, people: people, thresholds: options.thresholds, report: report)
            }
        }

        report("Stimmen werden erkannt", 0.8)
        // One voice embedding per line (the longest few hundred), for checking the speaker separation
        // against known voices and for the speakers' own embeddings.
        var lineEmbeddings: [Int: [Float]] = [:]
        let measured = lines.indices.filter { lines[$0].duration >= 1.0 }
            .sorted { lines[$0].duration > lines[$1].duration }
            .prefix(400)
        for (count, index) in measured.enumerated() {
            let line = lines[index]
            guard let audio = audioByChannel[line.channel] else { continue }
            let slice = Self.slice(audio, from: line.start, to: min(line.end, line.start + 10))
            if let embedding = try await engine.voiceEmbedding(slice) {
                lineEmbeddings[index] = embedding
            }
            if count % 20 == 0 { report("Stimmen werden erkannt", 0.8 + 0.1 * Double(count) / Double(max(measured.count, 1))) }
        }
        let isRoom = lines.allSatisfy { $0.channel == .microphone }

        var embeddings: [String: [Float]] = [:]
        var talk: [String: Double] = [:]
        var samples: [String: (Double, Double)] = [:]
        for (key, indices) in Dictionary(grouping: lines.indices, by: { lines[$0].speakerKey }) {
            talk[key] = indices.reduce(0) { $0 + lines[$1].duration }
            if let longest = indices.max(by: { lines[$0].duration < lines[$1].duration }) {
                samples[key] = (lines[longest].start, min(lines[longest].end, lines[longest].start + 12))
            }
            embeddings[key] = VoiceMath.weightedMean(indices.compactMap { index in
                lineEmbeddings[index].map { ($0, Float(min(lines[index].duration, 10))) }
            })
        }

        // In a room recording, one of the voices may be the user's.
        if isRoom, !lines.contains(where: { $0.speakerKey == MeetingSpeaker.meKey }),
           let key = Self.roomVoiceOfUser(embeddings, library: library, me: me.id, threshold: options.thresholds.automatic) {
            for index in lines.indices where lines[index].speakerKey == key {
                lines[index].speakerKey = MeetingSpeaker.meKey
            }
            embeddings[MeetingSpeaker.meKey] = embeddings.removeValue(forKey: key)
            talk[MeetingSpeaker.meKey] = talk.removeValue(forKey: key)
            samples[MeetingSpeaker.meKey] = samples.removeValue(forKey: key)
        }

        // Name the voices.
        let remoteKeys = Self.orderedKeys(lines).filter { $0 != MeetingSpeaker.meKey }
        let labels = Dictionary(uniqueKeysWithValues: remoteKeys.enumerated().map { ($1, Strings.speakerLabel($0 + 1)) })
        let voices = remoteKeys.map { VoiceToName(key: $0, embedding: embeddings[$0], talkTime: talk[$0] ?? 0) }
        let finder = NameEvidenceFinder(knownNames: people.map(\.name) + meeting.attendees.map(\.name))
        let spoken = lines.map { SpokenLine(speakerKey: $0.speakerKey, text: $0.text) }
        let guesses = NameEvidenceFinder.guesses(from: finder.clues(in: spoken))
        let peopleById = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        var identifier = SpeakerIdentifier(library: library, people: people, attendees: meeting.attendees, thresholds: options.thresholds) { key in
            key == MeetingSpeaker.meKey ? me.firstName : (labels[key] ?? key)
        }
        var decisions = identifier.decide(voices: voices, guesses: guesses)
        // Second pass: quotes can now name the people that were recognised in the first.
        let known = decisions.compactMapValues { $0.personId.flatMap { peopleById[$0]?.firstName } }
        identifier.nameOfKey = { key in
            if key == MeetingSpeaker.meKey { return me.firstName }
            return known[key] ?? labels[key] ?? key
        }
        decisions = identifier.decide(voices: voices, guesses: guesses)

        report("Wird gespeichert", 0.93)
        var speakers: [MeetingSpeaker] = []
        if lines.contains(where: { $0.speakerKey == MeetingSpeaker.meKey }) {
            speakers.append(MeetingSpeaker(
                meetingId: meetingId, key: MeetingSpeaker.meKey, label: Strings.me, personId: me.id, assignment: .confirmed,
                confidence: 1, talkTime: talk[MeetingSpeaker.meKey] ?? 0, embedding: embeddings[MeetingSpeaker.meKey]?.embeddingData,
                sampleStart: samples[MeetingSpeaker.meKey]?.0, sampleEnd: samples[MeetingSpeaker.meKey]?.1, channel: .microphone
            ))
        }
        for key in remoteKeys {
            let decision = decisions[key] ?? .unknown
            speakers.append(MeetingSpeaker(
                meetingId: meetingId, key: key, label: labels[key] ?? key, personId: decision.personId, assignment: decision.assignment,
                suggestedPersonId: decision.suggestedPersonId, suggestedName: decision.suggestedName, suggestionReason: decision.reason,
                confidence: decision.confidence, talkTime: talk[key] ?? 0, embedding: embeddings[key]?.embeddingData,
                sampleStart: samples[key]?.0, sampleEnd: samples[key]?.1,
                channel: lines.first { $0.speakerKey == key }?.channel ?? .system
            ))
        }
        let segments = lines.map {
            Segment(meetingId: meetingId, speakerKey: $0.speakerKey, channel: $0.channel, start: $0.start, end: $0.end, text: $0.text)
        }
        try database.replaceTranscript(meetingId: meetingId, segments: segments, speakers: speakers)

        // Learn: the user's own voice from the microphone, and voices recognised with high confidence.
        if micLearnable, let mine = embeddings[MeetingSpeaker.meKey] {
            try learn(mine, for: me.id, meetingId: meetingId, duration: talk[MeetingSpeaker.meKey] ?? 0, library: &library)
        }
        if options.learnVoices {
            for speaker in speakers where speaker.assignment == .automatic && speaker.confidence >= 0.82 && speaker.talkTime >= 8 {
                if let personId = speaker.personId, let embedding = speaker.embedding {
                    try learn([Float](embeddingData: embedding), for: personId, meetingId: meetingId, duration: speaker.talkTime, library: &library)
                }
            }
        }

        let text = lines.map(\.text).joined(separator: " ")
        let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        try database.update(meetingId: meetingId) { meeting in
            meeting.status = .ready
            meeting.progress = 1
            meeting.processingStep = nil
            meeting.duration = max(meeting.duration, duration)
            meeting.language = language
            meeting.transcriptionModel = options.model.title
        }
        report("Fertig", 1)
    }

    /// A recording with everyone on one channel: transcribe, separate the voices, number them.
    private func room(_ audio: [Float], channel: Channel, meStart: Double, library: VoiceLibrary, people: [Person], thresholds: VoiceThresholds, report: @escaping Progress) async throws -> [DraftLine] {
        report("Wird transkribiert", meStart)
        let text = try await engine.transcribe(audio)
        report("Stimmen werden getrennt", 0.45)
        let diarization = try await engine.diarize(audio) { fraction in report("Stimmen werden getrennt", 0.45 + fraction * 0.3) }
        let turns = try await refined(diarization.turns, words: text.words, audio: audio, library: library, people: people, thresholds: thresholds, excluding: [])
        let speakers = TranscriptAssembly.speakers(for: text.words, turns: turns)
        let breaks = TranscriptAssembly.pauseBreaks(words: text.words, turns: turns)
        return TranscriptAssembly.renumbered(TranscriptAssembly.lines(words: text.words, speakers: speakers, channel: channel, breaks: breaks)).lines
    }

    /// Checks the diarizer's turns against the voice library and splits voices that turn out to be
    /// several known people (see `VoiceRefinement`).
    private func refined(_ turns: [SpeakerTurn], words: [TimedWord], audio: [Float], library: VoiceLibrary, people: [Person], thresholds: VoiceThresholds, excluding: Set<String>) async throws -> [SpeakerTurn] {
        guard !library.isEmpty, !turns.isEmpty else { return turns }
        let finder = NameEvidenceFinder(knownNames: people.map(\.name))
        var units: [VoiceRefinement.Unit] = []
        for turn in turns {
            var embedding: [Float]?
            if turn.end - turn.start >= 1.0 {
                embedding = try await engine.voiceEmbedding(Self.slice(audio, from: turn.start, to: min(turn.end, turn.start + 30)))
            }
            let text = TranscriptAssembly.join(words.filter { ($0.start + $0.end) / 2 >= turn.start && ($0.start + $0.end) / 2 < turn.end })
            units.append(VoiceRefinement.Unit(key: turn.speaker, duration: turn.end - turn.start, embedding: embedding, introducedNames: finder.introducedNames(in: text)))
        }
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let keys = VoiceRefinement.refine(units, library: library, thresholds: thresholds, excluding: excluding) { names[$0] }
        return zip(turns, keys).map { turn, key in SpeakerTurn(speaker: key, start: turn.start, end: turn.end) }
    }

    private func speechSeconds(_ audio: [Float]) async throws -> Double {
        guard audio.count >= SpeechAudio.samples(0.5) else { return 0 }
        // Silence from a tap without permission or an empty call is exactly zero; skip the model then.
        if SpeechAudio.rms(audio) < 1e-5 { return 0 }
        return try await engine.speechRegions(in: audio).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Keeps a new voice sample for a person, unless it repeats one already kept.
    private func learn(_ embedding: [Float], for personId: String, meetingId: String, duration: Double, library: inout VoiceLibrary) throws {
        let existing = library.voices[personId] ?? []
        if existing.contains(where: { VoiceMath.cosine($0, embedding) >= Self.redundantSimilarity }) { return }
        try database.save(Voiceprint(personId: personId, embedding: embedding.embeddingData, meetingId: meetingId, duration: duration))
        library.add(embedding, to: personId)
        try database.trimVoiceprints(of: personId, keeping: Self.maxVoiceprintsPerPerson)
    }

    /// The voice closest to the user's own, if it is close enough and doesn't sound even more like
    /// someone else the app knows.
    static func roomVoiceOfUser(_ embeddings: [String: [Float]], library: VoiceLibrary, me: String, threshold: Float) -> String? {
        embeddings.compactMap { key, embedding -> (key: String, similarity: Float)? in
            guard let best = library.rank(embedding).first, best.personId == me, best.similarity >= threshold else { return nil }
            return (key, best.similarity)
        }
        .max { $0.similarity < $1.similarity }?
        .key
    }

    static func slice(_ audio: [Float], from start: Double, to end: Double) -> ArraySlice<Float> {
        let lower = max(0, min(audio.count, SpeechAudio.samples(start)))
        let upper = max(lower, min(audio.count, SpeechAudio.samples(end)))
        return audio[lower..<upper]
    }

    static func orderedKeys(_ lines: [DraftLine]) -> [String] {
        var seen: [String] = []
        for line in lines where !seen.contains(line.speakerKey) { seen.append(line.speakerKey) }
        return seen
    }
}

extension AppDatabase {
    /// Drops a person's oldest voice samples beyond `keeping`.
    public func trimVoiceprints(of personId: String, keeping: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM voiceprint WHERE personId = ? AND id NOT IN (
                    SELECT id FROM voiceprint WHERE personId = ? ORDER BY createdAt DESC LIMIT ?
                )
                """, arguments: [personId, personId, keeping])
        }
    }
}

/// Shrinks a processed recording: the uncompressed recording files become compressed ones.
public enum AudioArchiver {
    public static func compress(meetingId: String) throws {
        for channel in Channel.allCases {
            let raw = AppPaths.rawFile(for: meetingId, channel: channel)
            guard FileManager.default.fileExists(atPath: raw.path) else { continue }
            let target = AppPaths.audioFile(for: meetingId, channel: channel)
            let samples = try SpeechAudio.load(raw)
            let writer = try AudioFileWriter(url: target, encoding: .aac)
            var offset = 0
            let chunk = SpeechAudio.samples(30)
            while offset < samples.count {
                let end = min(offset + chunk, samples.count)
                try writer.write(Array(samples[offset..<end]))
                offset = end
            }
            writer.close()
            // Only drop the original once the compressed file reads back with the same length.
            let written = SpeechAudio.duration(of: target)
            if abs(written - SpeechAudio.seconds(samples.count)) < 1.0 {
                try FileManager.default.removeItem(at: raw)
            }
        }
    }

    /// Deletes a meeting's audio entirely (the transcript stays).
    public static func deleteAudio(meetingId: String) {
        for channel in Channel.allCases {
            try? FileManager.default.removeItem(at: AppPaths.rawFile(for: meetingId, channel: channel))
            try? FileManager.default.removeItem(at: AppPaths.audioFile(for: meetingId, channel: channel))
        }
    }

    public static func hasAudio(meetingId: String) -> Bool {
        Channel.allCases.contains { AppPaths.existingAudio(for: meetingId, channel: $0) != nil } || AppPaths.existingImport(for: meetingId) != nil
    }
}
