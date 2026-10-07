import AVFoundation
import Foundation
import NaturalLanguage

/// The full pass over a finished recording: transcribe both channels with the large model, separate
/// the voices, name them, and save the result. Replaces the live transcript.
public final class MeetingProcessor: @unchecked Sendable {
    public struct Options: Sendable {
        public var model: TranscriptionModel
        public var thresholds: VoiceThresholds
        /// Let voices the app recognised by itself refine what it knows about people. (Confirmed voices
        /// always count.)
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
        var microphone = try AppPaths.existingAudio(for: meetingId, channel: .microphone).map(SpeechAudio.load) ?? []
        let system = try AppPaths.existingAudio(for: meetingId, channel: .system).map(SpeechAudio.load) ?? []
        let imported = try importURL.map(SpeechAudio.load) ?? []
        let duration = SpeechAudio.seconds(max(microphone.count, system.count, imported.count))

        let people = try database.people()
        let me = try database.mePerson(defaultName: options.defaultMyName)
        // Everyone's voice, but nothing of this meeting itself: what was said about it before comes back
        // through the confirmed names below, not by recognising the meeting in itself.
        let library = VoiceLibrary(samples: try database.voiceSamples().filter {
            $0.meetingId != meetingId && (options.learnVoices || $0.source != .automatic)
        })

        var lines: [DraftLine] = []
        var audioByChannel: [Channel: [Float]] = [:]

        if !imported.isEmpty {
            audioByChannel[.microphone] = imported
            lines = try await room(imported, channel: .microphone, meStart: 0.1, library: library, people: people, thresholds: options.thresholds, report: report)
        } else {
            report("Sprache wird gesucht", 0.08)
            let systemSpeech = try await speechSeconds(system)
            // Loudness of the microphone before and after the echo came out, and of the call, to tell the
            // user's words from what is left of the echo (see `MicrophoneWords`).
            var echoLevels: (raw: [Float], cleaned: [Float], call: [Float])?
            if systemSpeech >= 3, !microphone.isEmpty {
                // Played through speakers, the call comes back into the microphone: a second, later copy of
                // every voice in the recording and in the user's own lines.
                report("Echo wird entfernt", 0.09)
                if let cleaned = EchoSuppressor.clean(microphone: microphone, reference: system) {
                    echoLevels = (MicrophoneWords.levels(microphone), MicrophoneWords.levels(cleaned), MicrophoneWords.levels(system))
                    microphone = cleaned
                    try? Self.saveCleanedMicrophone(cleaned, meetingId: meetingId)
                } else {
                    try? FileManager.default.removeItem(at: AppPaths.cleanedMicrophoneFile(for: meetingId))
                }
            }
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
                    var words = microphoneText.words
                    if let echoLevels {
                        // Leaving out the echo's words also splits the user's lines where the call talked.
                        words = MicrophoneWords.own(words, cleaned: echoLevels.cleaned, raw: echoLevels.raw, call: echoLevels.call)
                    }
                    let all = TranscriptAssembly.lines(
                        words: words,
                        speakers: words.map { _ in MeetingSpeaker.meKey },
                        channel: .microphone
                    )
                    microphoneLines = TranscriptAssembly.removeEchoes(microphone: all, system: systemLines)
                }
                lines = TranscriptAssembly.merged(systemLines, microphoneLines)
            } else if microphoneSpeech >= 0.5 {
                // No call audio: a meeting in the room, everyone on the microphone.
                lines = try await room(microphone, channel: .microphone, meStart: 0.12, library: library, people: people, thresholds: options.thresholds, report: report)
            }
        }

        report("Stimmen werden erkannt", 0.8)
        // A voice embedding for every line long enough to have one: the app learns voices line by line, and
        // a line that sounds like someone else than the rest of its speaker stands out.
        var lineEmbeddings: [Int: [Float]] = [:]
        let measured = lines.indices.filter { lines[$0].duration >= 1.0 }
            .sorted { lines[$0].duration > lines[$1].duration }
            .prefix(Self.maximumEmbeddedLines)
        for (count, index) in measured.enumerated() {
            let line = lines[index]
            guard let audio = audioByChannel[line.channel] else { continue }
            if let embedding = try await engine.voiceEmbedding(Self.slice(audio, from: line.start, to: min(line.end, line.start + 20))) {
                lineEmbeddings[index] = embedding
            }
            if count % 20 == 0 { report("Stimmen werden erkannt", 0.8 + 0.1 * Double(count) / Double(max(measured.count, 1))) }
        }
        let isRoom = lines.allSatisfy { $0.channel == .microphone }

        // Confirmed names from before (live, or an earlier pass over this meeting) stay with the same speech.
        // Read only now: the user may have named someone in the minutes this pass took.
        let carried = Self.carriedOver(from: try database.detail(of: meetingId), to: &lines)
        let embeddings = Self.speakerVoices(lines, lineEmbeddings: lineEmbeddings)
        var voiceOf = embeddings
        var talk: [String: Double] = [:]
        var samples: [String: (Double, Double)] = [:]
        for (key, indices) in Dictionary(grouping: lines.indices, by: { lines[$0].speakerKey }) {
            talk[key] = indices.reduce(0) { $0 + lines[$1].duration }
            if let longest = indices.max(by: { lines[$0].duration < lines[$1].duration }) {
                samples[key] = (lines[longest].start, min(lines[longest].end, lines[longest].start + 12))
            }
        }

        // In a room recording, one of the voices may be the user's.
        var userFoundByVoice = false
        if isRoom, !lines.contains(where: { $0.speakerKey == MeetingSpeaker.meKey }),
           let key = Self.roomVoiceOfUser(embeddings.filter { carried.assignments[$0.key] == nil }, library: library, me: me.id, threshold: options.thresholds.automatic) {
            for index in lines.indices where lines[index].speakerKey == key {
                lines[index].speakerKey = MeetingSpeaker.meKey
            }
            voiceOf[MeetingSpeaker.meKey] = voiceOf.removeValue(forKey: key)
            talk[MeetingSpeaker.meKey] = talk.removeValue(forKey: key)
            samples[MeetingSpeaker.meKey] = samples.removeValue(forKey: key)
            userFoundByVoice = true
        }

        // Name the voices.
        let remoteKeys = Self.orderedKeys(lines).filter { $0 != MeetingSpeaker.meKey }
        let labels = Dictionary(uniqueKeysWithValues: remoteKeys.enumerated().map { ($1, Strings.speakerLabel($0 + 1)) })
        let voices = remoteKeys.filter { carried.assignments[$0] == nil }.map { VoiceToName(key: $0, embedding: voiceOf[$0], talkTime: talk[$0] ?? 0) }
        let finder = NameEvidenceFinder(knownNames: people.map(\.name) + meeting.attendees.map(\.name))
        let spoken = lines.map { SpokenLine(speakerKey: $0.speakerKey, text: $0.text) }
        let guesses = NameEvidenceFinder.guesses(from: finder.clues(in: spoken))
        let peopleById = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        var identifier = SpeakerIdentifier(library: library, people: people, attendees: meeting.attendees, thresholds: options.thresholds) { key in
            key == MeetingSpeaker.meKey ? me.firstName : (labels[key] ?? key)
        }
        var decisions = identifier.decide(voices: voices, guesses: guesses)
        // Second pass: quotes can now name the people that were recognised in the first.
        var known = decisions.compactMapValues { $0.personId.flatMap { peopleById[$0]?.firstName } }
        for (key, personId) in carried.assignments { known[key] = personId.flatMap { peopleById[$0]?.firstName } }
        identifier.nameOfKey = { key in
            if key == MeetingSpeaker.meKey { return me.firstName }
            return known[key] ?? labels[key] ?? key
        }
        decisions = identifier.decide(voices: voices, guesses: guesses)

        report("Wird gespeichert", 0.93)
        var speakers: [MeetingSpeaker] = []
        if lines.contains(where: { $0.speakerKey == MeetingSpeaker.meKey }) {
            speakers.append(MeetingSpeaker(
                meetingId: meetingId, key: MeetingSpeaker.meKey, label: Strings.meLabel, personId: me.id,
                assignment: userFoundByVoice ? .automatic : .confirmed,
                confidence: 1, talkTime: talk[MeetingSpeaker.meKey] ?? 0, embedding: voiceOf[MeetingSpeaker.meKey]?.embeddingData,
                sampleStart: samples[MeetingSpeaker.meKey]?.0, sampleEnd: samples[MeetingSpeaker.meKey]?.1, channel: .microphone
            ))
        }
        for key in remoteKeys {
            var speaker = MeetingSpeaker(
                meetingId: meetingId, key: key, label: labels[key] ?? key, talkTime: talk[key] ?? 0, embedding: voiceOf[key]?.embeddingData,
                sampleStart: samples[key]?.0, sampleEnd: samples[key]?.1,
                channel: lines.first { $0.speakerKey == key }?.channel ?? .system
            )
            speaker.rejectedPersonIds = carried.rejections[key] ?? []
            if let carriedPerson = carried.assignments[key] {
                speaker.personId = carriedPerson
                speaker.assignment = .confirmed
                speaker.confidence = 1
            } else if let decision = decisions[key], [decision.personId, decision.suggestedPersonId].compactMap({ $0 }).contains(where: speaker.rejectedPersonIds.contains) {
                // Whom the user ruled out is not proposed again.
                speaker.assignment = .unknown
            } else {
                let decision = decisions[key] ?? .unknown
                speaker.personId = decision.personId
                speaker.assignment = decision.assignment
                speaker.suggestedPersonId = decision.suggestedPersonId
                speaker.suggestedName = decision.suggestedName
                speaker.suggestionReason = decision.reason
                speaker.confidence = decision.confidence
                speaker.candidatePersonIds = decision.candidates.filter { !speaker.rejectedPersonIds.contains($0) }
            }
            speakers.append(speaker)
        }
        let segments = lines.indices.map { index in
            let line = lines[index]
            return Segment(
                meetingId: meetingId, speakerKey: line.speakerKey, channel: line.channel, start: line.start, end: line.end, text: line.text,
                embedding: lineEmbeddings[index]?.embeddingData, voiceIgnored: carried.ignoredLines.contains(index)
            )
        }
        try database.replaceTranscript(meetingId: meetingId, segments: segments, speakers: speakers)

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

    /// At most this many lines get a voice embedding, the longest ones.
    static let maximumEmbeddedLines = 800

    /// Gives the lines of a meeting processed before lines had voices of their own their embeddings, from
    /// the audio that is still there. The transcript stays as it is.
    public func embedLines(meetingId: String, model: TranscriptionModel) async throws {
        guard let detail = try database.detail(of: meetingId) else { return }
        let lines = detail.segments.filter { $0.embedding == nil && $0.duration >= 1 && $0.id != nil }
        guard !lines.isEmpty else { return }
        try await engine.prepare(model: model)
        var audio: [Channel: [Float]] = [:]
        if let imported = AppPaths.existingImport(for: meetingId) {
            audio[.microphone] = try SpeechAudio.load(imported)
        } else {
            for channel in Channel.allCases {
                if let url = AppPaths.playbackAudio(for: meetingId, channel: channel) { audio[channel] = try SpeechAudio.load(url) }
            }
        }
        var embeddings: [Int64: [Float]] = [:]
        for line in lines.sorted(by: { $0.duration > $1.duration }).prefix(Self.maximumEmbeddedLines) {
            guard let samples = audio[line.channel], let id = line.id else { continue }
            if let embedding = try await engine.voiceEmbedding(Self.slice(samples, from: line.start, to: min(line.end, line.start + 20))) {
                embeddings[id] = embedding
            }
        }
        guard !embeddings.isEmpty else { return }
        try database.saveLineEmbeddings(embeddings, meetingId: meetingId)
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

    /// What the user settled about a meeting before it was processed (again): confirmed names and lines
    /// left out of a voice, matched to the new transcript by time.
    struct CarriedOver {
        /// Speaker key → the person confirmed for that speech; nil inside: confirmed as nobody to name.
        var assignments: [String: String?] = [:]
        /// Speaker key → people the user said that speech is not.
        var rejections: [String: [String]] = [:]
        /// Indices of lines the user had left out of their speaker's voice.
        var ignoredLines: Set<Int> = []
    }

    /// Carries confirmed names over from the meeting's previous transcript (the live one, or an earlier
    /// pass): a new voice whose speech is mostly what a confirmed speaker said before is that person. Two
    /// new voices that were one confirmed speaker become one again.
    static func carriedOver(from previous: MeetingDetail?, to lines: inout [DraftLine]) -> CarriedOver {
        guard let previous else { return CarriedOver() }
        let nobody = ""
        var stretches: [String: [(Double, Double)]] = [:]
        let confirmed = Dictionary(uniqueKeysWithValues: previous.speakers.filter { $0.assignment == .confirmed && !$0.isMe }.map { ($0.key, $0) })
        for segment in previous.segments {
            guard let speaker = confirmed[segment.speakerKey] else { continue }
            stretches[speaker.personId ?? nobody, default: []].append((segment.start, segment.end))
        }
        let ignored = previous.segments.filter(\.voiceIgnored).map { ($0.start, $0.end) }
        func overlap(_ start: Double, _ end: Double, _ ranges: [(Double, Double)]) -> Double {
            ranges.reduce(0) { $0 + max(0, min(end, $1.1) - max(start, $1.0)) }
        }

        var result = CarriedOver()

        // A voice the user took out of their own microphone track (someone in the room, the call through the
        // speakers) and named stays out of it.
        let separated = previous.speakers.filter { $0.assignment == .confirmed && !$0.isMe && $0.channel == .microphone }
        if !separated.isEmpty {
            var used = Set(lines.map(\.speakerKey))
            var keyFor: [String: String] = [:]
            for index in lines.indices where lines[index].speakerKey == MeetingSpeaker.meKey {
                let best = separated.map { speaker in
                    (speaker, overlap(lines[index].start, lines[index].end, previous.segments.filter { $0.speakerKey == speaker.key }.map { ($0.start, $0.end) }))
                }.max { $0.1 < $1.1 }
                guard let best, best.1 >= lines[index].duration * 0.5 else { continue }
                if keyFor[best.0.key] == nil {
                    var key = best.0.key
                    var number = 1
                    while used.contains(key) { key = "S\(number)"; number += 1 }
                    used.insert(key)
                    keyFor[best.0.key] = key
                }
                lines[index].speakerKey = keyFor[best.0.key]!
            }
        }

        var keyOfPerson: [String: String] = [:]
        let talk = Dictionary(grouping: lines, by: \.speakerKey).mapValues { $0.reduce(0) { $0 + $1.duration } }
        let keys = orderedKeys(lines).filter { $0 != MeetingSpeaker.meKey }.sorted { (talk[$0] ?? 0) > (talk[$1] ?? 0) }
        for key in keys where !stretches.isEmpty {
            let own = lines.filter { $0.speakerKey == key }
            let spoken = talk[key] ?? 0
            let best = stretches.map { person, ranges in (person, own.reduce(0) { $0 + overlap($1.start, $1.end, ranges) }) }
                .max { $0.1 < $1.1 }
            guard let best, best.1 >= max(2, spoken * 0.5) else { continue }
            if best.0 != nobody, let target = keyOfPerson[best.0] {
                for index in lines.indices where lines[index].speakerKey == key { lines[index].speakerKey = target }
            } else {
                keyOfPerson[best.0] = key
                result.assignments[key] = .some(best.0 == nobody ? nil : best.0)
            }
        }
        if !ignored.isEmpty {
            for index in lines.indices where overlap(lines[index].start, lines[index].end, ignored) >= lines[index].duration * 0.5 {
                result.ignoredLines.insert(index)
            }
        }
        // "That's not them" sticks to the speech too.
        let rejecting = previous.speakers.filter { !$0.rejectedPersonIds.isEmpty }
        if !rejecting.isEmpty {
            let talkNow = Dictionary(grouping: lines, by: \.speakerKey).mapValues { $0.reduce(0) { $0 + $1.duration } }
            for (key, own) in Dictionary(grouping: lines, by: \.speakerKey) where key != MeetingSpeaker.meKey {
                for speaker in rejecting {
                    let ranges = previous.segments.filter { $0.speakerKey == speaker.key }.map { ($0.start, $0.end) }
                    let shared = own.reduce(0) { $0 + overlap($1.start, $1.end, ranges) }
                    if shared >= max(2, (talkNow[key] ?? 0) * 0.5) {
                        result.rejections[key, default: []] += speaker.rejectedPersonIds.filter { !(result.rejections[key] ?? []).contains($0) }
                    }
                }
            }
        }
        return result
    }

    /// Each speaker's voice: the centroid of their biggest group of lines, so a few lines of someone else
    /// (crosstalk, an echo) don't blur it.
    static func speakerVoices(_ lines: [DraftLine], lineEmbeddings: [Int: [Float]]) -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for (key, indices) in Dictionary(grouping: lines.indices, by: { lines[$0].speakerKey }) {
            let voiced = indices.filter { lineEmbeddings[$0] != nil }
            guard !voiced.isEmpty else { continue }
            let vectors = voiced.map { lineEmbeddings[$0]! }
            let durations = voiced.map { lines[$0].duration }
            guard let main = VoiceClustering.groups(vectors, durations: durations).groups.first else { continue }
            result[key] = VoiceClustering.centroid(of: main, in: vectors, weights: durations.map { Float(min(max($0, 0.5), 20)) })
        }
        return result
    }

    /// Keeps the microphone track without the call's echo, for playback.
    static func saveCleanedMicrophone(_ samples: [Float], meetingId: String) throws {
        let writer = try AudioFileWriter(url: AppPaths.cleanedMicrophoneFile(for: meetingId), encoding: .aac)
        defer { writer.close() }
        var offset = 0
        let chunk = SpeechAudio.samples(30)
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            try writer.write(Array(samples[offset..<end]))
            offset = end
        }
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
        try? FileManager.default.removeItem(at: AppPaths.cleanedMicrophoneFile(for: meetingId))
        for ext in ["m4a", "caf"] { try? FileManager.default.removeItem(at: AppPaths.originalSystemFile(for: meetingId, extension: ext)) }
    }

    public static func hasAudio(meetingId: String) -> Bool {
        Channel.allCases.contains { AppPaths.existingAudio(for: meetingId, channel: $0) != nil } || AppPaths.existingImport(for: meetingId) != nil
    }
}
