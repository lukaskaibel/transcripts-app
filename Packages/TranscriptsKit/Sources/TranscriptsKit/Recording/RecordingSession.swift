import Foundation
import Observation
import os

/// Recording time that stands still while paused. Safe to read from any thread.
final class RecordingClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var startedAt: TimeInterval?
    private var pausedAt: TimeInterval?
    private var pausedTotal: TimeInterval = 0

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() { lock.withLock { startedAt = Self.now() } }

    func pause() { lock.withLock { if pausedAt == nil { pausedAt = Self.now() } } }

    func resume() {
        lock.withLock {
            if let pausedAt {
                pausedTotal += Self.now() - pausedAt
                self.pausedAt = nil
            }
        }
    }

    var isPaused: Bool { lock.withLock { pausedAt != nil } }

    /// Seconds recorded so far, pauses left out.
    var elapsed: TimeInterval {
        lock.withLock {
            guard let startedAt else { return 0 }
            let end = pausedAt ?? Self.now()
            return max(0, end - startedAt - pausedTotal)
        }
    }
}

/// A line of the live transcript.
public struct LiveLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var speakerKey: String
    public var channel: Channel
    public var start: Double
    public var end: Double
    public var text: String
    public var isPartial: Bool
}

/// A voice heard so far in the running meeting.
public struct LiveVoice: Equatable, Sendable {
    public var key: String
    public var label: String
    public var personId: String?
    public var name: String?
    /// A name heard in the conversation that could be this voice ("hier ist Paula").
    public var suggestedName: String?
    public var speech: Double
}

/// Something wrong with the microphone during a recording.
public enum MicrophoneProblem: Equatable, Sendable {
    /// Samples arrive, but every one is exactly zero: macOS hands out silence, usually for lack of permission.
    case silent
    /// Nothing arrives at all, not even after restarting the capture.
    case noSignal

    public var message: String {
        switch self {
        case .silent: String(localized: "Vom Mikrofon kommt nur Stille. Ist es stummgeschaltet? Sonst prüfe unter Datenschutz & Sicherheit → Mikrofon, ob Transcripts erlaubt ist.")
        case .noSignal: String(localized: "Das Mikrofon liefert nichts. Prüfe das Eingabegerät in den Einstellungen unter Aufnahme.")
        }
    }

    public var shortMessage: String {
        switch self {
        case .silent: String(localized: "Mikrofon stumm oder ohne Zugriff")
        case .noSignal: String(localized: "Mikrofon liefert nichts")
        }
    }
}

/// A moment flagged during the recording.
public struct LiveMarker: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var time: Double
    public var text: String
}

/// One running recording: microphone and call audio into files, plus the live transcript.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable, Sendable {
        case starting
        case recording
        case paused
        case stopping
        case stopped
    }

    public let meetingId: String
    public let startedAt: Date
    public private(set) var state: State = .starting
    public var title: String
    public private(set) var source: String?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var microphoneLevel: Float = 0
    public private(set) var systemLevel: Float = 0
    public private(set) var lines: [LiveLine] = []
    public private(set) var partials: [Channel: LiveLine] = [:]
    public private(set) var voices: [String: LiveVoice] = [:]
    public private(set) var markers: [LiveMarker] = []
    /// The voice that spoke last, for the floating recorder.
    public private(set) var currentSpeakerKey: String?
    /// True when the call audio has stayed silent although other apps were playing sound.
    public private(set) var systemAudioSeemsBlocked = false
    public private(set) var microphoneProblem: MicrophoneProblem?
    public private(set) var errorMessage: String?
    public let capturesSystemAudio: Bool

    private let database: AppDatabase
    private let engine: SpeechEngine
    private let clock = RecordingClock()
    private let microphone: AudioSource
    private let system: AudioSource
    private var channelTasks: [Task<Void, Never>] = []
    private var continuations: [Channel: AsyncStream<CapturedChunk>.Continuation] = [:]
    private var transcribers: [Channel: LiveTranscriber] = [:]
    private var tracker: LiveSpeakerTracker
    private var library: VoiceLibrary
    private var people: [String: Person]
    private let attendees: [Attendee]
    private let thresholds: VoiceThresholds
    private var timer: Task<Void, Never>?
    private var silentSystemSeconds = 0

    public struct Configuration: Sendable {
        public var microphoneUID: String?
        public var captureSystemAudio: Bool
        public var thresholds: VoiceThresholds

        public init(microphoneUID: String? = nil, captureSystemAudio: Bool = true, thresholds: VoiceThresholds = .standard) {
            self.microphoneUID = microphoneUID
            self.captureSystemAudio = captureSystemAudio
            self.thresholds = thresholds
        }
    }

    /// `sources` replaces the microphone and the system audio tap, for tests that play files instead.
    /// `library` is everyone's voice as the app knows it; loaded from the database when not given.
    public init(meeting: Meeting, database: AppDatabase, engine: SpeechEngine = .shared, configuration: Configuration, library: VoiceLibrary? = nil, sources: [Channel: AudioSource]? = nil) {
        meetingId = meeting.id
        startedAt = meeting.startedAt
        title = meeting.title
        source = meeting.source
        self.database = database
        self.engine = engine
        thresholds = configuration.thresholds
        tracker = LiveSpeakerTracker(threshold: configuration.thresholds.sameSpeaker)
        self.library = library ?? VoiceLibrary(samples: (try? database.voiceSamples()) ?? [])
        people = Dictionary(uniqueKeysWithValues: ((try? database.people()) ?? []).map { ($0.id, $0) })
        attendees = meeting.attendees
        capturesSystemAudio = configuration.captureSystemAudio && (sources == nil || sources?[.system] != nil)
        if let sources {
            microphone = sources[.microphone] ?? FileAudioSource.silent
            system = sources[.system] ?? FileAudioSource.silent
        } else {
            let capture = MicrophoneCapture()
            capture.deviceUID = configuration.microphoneUID
            microphone = capture
            system = SystemAudioCapture()
        }
    }

    // MARK: Lifecycle

    public func start() async throws {
        let channels: [Channel] = capturesSystemAudio ? [.microphone, .system] : [.microphone]
        for channel in channels {
            let writer = try AudioFileWriter(url: AppPaths.rawFile(for: meetingId, channel: channel), encoding: .pcm)
            let (stream, continuation) = AsyncStream<CapturedChunk>.makeStream(bufferingPolicy: .unbounded)
            continuations[channel] = continuation
            let transcriber = LiveTranscriber(channel: channel, engine: engine) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            transcribers[channel] = transcriber
            let onLevel: @Sendable (Float, Bool) -> Void = { [weak self] level, silent in
                Task { @MainActor in self?.setLevel(level, silent: silent, for: channel) }
            }
            channelTasks.append(Task.detached(priority: .userInitiated) { [clock] in
                await Self.pump(stream, channel: channel, writer: writer, transcriber: transcriber, clock: clock, level: onLevel)
            })
        }

        let continuations = continuations
        let clock = clock
        // Stamped when they arrive, not when the pump gets to them: the pump also feeds the live transcriber
        // and can fall behind, and judged by the time it catches up, a channel would look short of samples
        // and get silence padded in that never was.
        microphone.onSamples = { samples in
            continuations[.microphone]?.yield(CapturedChunk(samples: samples, elapsed: clock.elapsed, paused: clock.isPaused))
        }
        system.onSamples = { samples in
            continuations[.system]?.yield(CapturedChunk(samples: samples, elapsed: clock.elapsed, paused: clock.isPaused))
        }

        clock.start()
        lastMicrophoneSignal = Date()
        do {
            try microphone.start()
        } catch {
            stopCaptures()
            throw error
        }
        if capturesSystemAudio {
            do {
                try system.start()
            } catch {
                // The call side is a bonus; a failed tap must not cost the user their own recording.
                errorMessage = error.localizedDescription
            }
        }
        state = .recording
        startTimer()
    }

    public func pause() {
        guard state == .recording else { return }
        clock.pause()
        state = .paused
        Task { for transcriber in transcribers.values { await transcriber.finish() } }
    }

    public func resume() {
        guard state == .paused else { return }
        clock.resume()
        lastMicrophoneSignal = Date()
        microphoneZerosSince = nil
        state = .recording
    }

    /// Stops capturing and waits until every sample is in the files and the live transcript.
    public func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        timer?.cancel()
        stopCaptures()
        for task in channelTasks { await task.value }
        for transcriber in transcribers.values { await transcriber.finish() }
        // Let the last live events land before the meeting is handed on.
        try? await Task.sleep(for: .milliseconds(150))
        // Played-back files run faster than the clock; the files themselves know their length.
        let written = Channel.allCases.compactMap { AppPaths.existingAudio(for: meetingId, channel: $0) }.map(SpeechAudio.duration).max() ?? 0
        elapsed = max(clock.elapsed, written)
        let duration = elapsed
        try? database.update(meetingId: meetingId) { meeting in
            meeting.duration = duration
            meeting.status = .processing
        }
        state = .stopped
    }

    private func stopCaptures() {
        microphone.stop()
        system.stop()
        for continuation in continuations.values { continuation.finish() }
    }

    /// Moves one channel's samples from the capture to the file and the live transcriber.
    /// Samples as a capture delivered them, with the recording time they arrived at.
    struct CapturedChunk: Sendable {
        var samples: [Float]
        var elapsed: TimeInterval
        var paused: Bool
    }

    private nonisolated static func pump(
        _ stream: AsyncStream<CapturedChunk>,
        channel: Channel,
        writer: AudioFileWriter,
        transcriber: LiveTranscriber,
        clock: RecordingClock,
        level: @escaping @Sendable (_ level: Float, _ silent: Bool) -> Void
    ) async {
        var lastLevel = Date.distantPast
        var peak: Float = 0
        // Exact zeros, not just quiet: what macOS delivers to an app it doesn't let listen.
        var onlyZeros = true
        for await captured in stream {
            if captured.paused { continue }
            let chunk = captured.samples
            var samples = chunk
            // A capture that hiccupped (device switch, tap restart) is padded with silence so both
            // channels stay on the same timeline.
            let expected = SpeechAudio.samples(captured.elapsed)
            let behind = expected - (writer.samplesWritten + samples.count)
            if behind > SpeechAudio.samples(0.5) {
                samples = [Float](repeating: 0, count: behind) + samples
            }
            try? writer.write(samples)
            peak = max(peak, SpeechAudio.meterLevel(chunk))
            if onlyZeros, SpeechAudio.rms(chunk) > 0 { onlyZeros = false }
            if Date().timeIntervalSince(lastLevel) > 0.08 {
                level(peak, onlyZeros)
                peak = 0
                onlyZeros = true
                lastLevel = Date()
            }
            await transcriber.feed(samples)
        }
        writer.close()
        level(0, false)
    }

    private func startTimer() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = self.clock.elapsed
                self.checkMicrophone()
                self.checkSystemAudio()
            }
        }
    }

    private var lastSystemCheck = Date()

    private func checkSystemAudio() {
        guard capturesSystemAudio, state == .recording, Date().timeIntervalSince(lastSystemCheck) >= 5 else { return }
        lastSystemCheck = Date()
        if systemLevel > 0.001 {
            silentSystemSeconds = 0
            systemAudioSeemsBlocked = false
            return
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let othersPlaying = AudioSystem.processes().contains { $0.isRunningOutput && $0.pid != ownPid }
        silentSystemSeconds = othersPlaying ? silentSystemSeconds + 5 : 0
        systemAudioSeemsBlocked = silentSystemSeconds >= 20
    }

    private var lastMicrophoneSignal = Date()
    private var microphoneZerosSince: Date?

    /// Silence for a few seconds is a pause in talking; exact zeros, or nothing at all, is a broken microphone.
    private func checkMicrophone() {
        guard state == .recording else { return }
        let now = Date()
        if now.timeIntervalSince(lastMicrophoneSignal) > 5 {
            microphoneProblem = .noSignal
        } else if let since = microphoneZerosSince, now.timeIntervalSince(since) > 4 {
            microphoneProblem = .silent
        } else {
            microphoneProblem = nil
        }
    }

    private func setLevel(_ level: Float, silent: Bool, for channel: Channel) {
        switch channel {
        case .microphone:
            microphoneLevel = level
            lastMicrophoneSignal = Date()
            if silent {
                if microphoneZerosSince == nil { microphoneZerosSince = Date() }
            } else {
                microphoneZerosSince = nil
            }
        case .system:
            systemLevel = level
        }
    }

    // MARK: Live transcript

    private func handle(_ event: LiveEvent) {
        switch event {
        case .partial(let channel, let start, let text):
            let key = channel == .microphone ? MeetingSpeaker.meKey : (currentSystemKey ?? "S?")
            partials[channel] = LiveLine(id: "partial-\(channel.rawValue)", speakerKey: key, channel: channel, start: start, end: start, text: text, isPartial: true)
        case .silence(let channel):
            partials[channel] = nil
        case .final(let channel, let start, let end, let text, let speaker, let embedding, let voice):
            partials[channel] = nil
            var key: String
            if channel == .microphone {
                key = MeetingSpeaker.meKey
            } else if let speaker {
                // The live diarizer keeps its IDs for the session; give them our own numbering.
                if let known = diarizerKeys[speaker] {
                    key = known
                } else {
                    key = nextVoiceKey()
                    diarizerKeys[speaker] = key
                }
                if let embedding { liveEmbeddings[key] = embedding }
            } else if let embedding {
                key = tracker.assign(embedding, duration: end - start)
            } else {
                key = currentSystemKey ?? tracker.voices.first?.key ?? "S1"
            }
            if channel == .system {
                key = checked(key, voice: voice, text: text)
            }
            if channel == .system { currentSystemKey = key }
            currentSpeakerKey = key
            if isEcho(channel: channel, text: text, start: start, end: end) || soundsLikeTheCall(channel: channel, voice: voice) { return }
            addVoiceIfNeeded(key, channel: channel, speech: end - start)
            let segment = try? database.appendSegment(Segment(meetingId: meetingId, speakerKey: key, channel: channel, start: start, end: end, text: text))
            let line = LiveLine(id: "\(segment?.id ?? Int64(lines.count))", speakerKey: key, channel: channel, start: start, end: end, text: text, isPartial: false)
            let index = lines.lastIndex { $0.start <= start }.map { $0 + 1 } ?? 0
            lines.insert(line, at: index)
            if channel == .system { nameVoice(key) }
            lookForNames()
        }
    }

    private var currentSystemKey: String?
    private var diarizerKeys: [String: String] = [:]
    private var liveEmbeddings: [String: [Float]] = [:]

    private func nextVoiceKey() -> String {
        var number = 1
        while voices["S\(number)"] != nil || diarizerKeys.values.contains("S\(number)") { number += 1 }
        return "S\(number)"
    }

    /// The voice a line of the call belongs to, after checking it on its own (see `LiveLineCheck`).
    private func checked(_ key: String, voice: [Float]?, text: String) -> String {
        let outcome = LiveLineCheck.check(
            key: key, voice: voice, text: text, voices: voices, library: library,
            names: people.mapValues(\.name), me: people.values.first(where: \.isMe)?.id,
            thresholds: thresholds, finder: NameEvidenceFinder(knownNames: people.values.map(\.name))
        )
        switch outcome {
        case .keep:
            return key
        case .move(let other):
            return other
        case .newVoice(let personId, let spokenName):
            let suggestedName = spokenName.map { resolve($0).name }
            let newKey = nextVoiceKey()
            let label = Strings.speakerLabel(voices.values.filter { $0.key != MeetingSpeaker.meKey }.count + 1)
            let person = personId.flatMap { people[$0] }
            voices[newKey] = LiveVoice(key: newKey, label: label, personId: person?.id, name: person?.name, suggestedName: suggestedName, speech: 0)
            try? database.save(MeetingSpeaker(
                meetingId: meetingId, key: newKey, label: label, personId: person?.id,
                assignment: person == nil ? .unknown : .automatic, channel: .system
            ))
            return newKey
        }
    }

    /// The best current picture of a live voice.
    private func centroid(of key: String) -> [Float]? {
        liveEmbeddings[key] ?? tracker.centroid(of: key)
    }

    /// A line of the microphone whose voice is the call's, not the user's (speakers instead of headphones).
    private func soundsLikeTheCall(channel: Channel, voice: [Float]?) -> Bool {
        guard channel == .microphone, let voice else { return false }
        let me = people.values.first(where: \.isMe)?.id
        let user = me.flatMap { library.similarity(voice, to: $0) }
        let callVoices = voices.keys.filter { $0 != MeetingSpeaker.meKey }.compactMap { centroid(of: $0) }
        let known = library.rank(voice, excluding: me.map { [$0] } ?? []).first?.similarity
        guard let call = (callVoices.map { VoiceMath.cosine(voice, $0) } + [known].compactMap { $0 }).max() else { return false }
        return LiveLineCheck.isEchoOfCall(user: user, call: call)
    }

    /// The call played through speakers and came back into the microphone: don't show it twice.
    private func isEcho(channel: Channel, text: String, start: Double, end: Double) -> Bool {
        guard channel == .microphone else { return false }
        let mine = Set(text.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
        guard !mine.isEmpty else { return false }
        let nearby = lines.filter { $0.channel == .system && $0.end >= start - 1.5 && $0.start <= end + 1.5 }
        let theirs = Set(nearby.flatMap { $0.text.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) } })
        guard !theirs.isEmpty else { return false }
        return Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.6
    }

    private func addVoiceIfNeeded(_ key: String, channel: Channel, speech: Double) {
        if var voice = voices[key] {
            voice.speech += speech
            voices[key] = voice
            return
        }
        let isMe = key == MeetingSpeaker.meKey
        let label = isMe ? Strings.meLabel : Strings.speakerLabel(voices.values.filter { $0.key != MeetingSpeaker.meKey }.count + 1)
        var voice = LiveVoice(key: key, label: label, personId: nil, name: nil, suggestedName: nil, speech: speech)
        if isMe, let me = people.values.first(where: \.isMe) {
            voice.personId = me.id
        }
        voices[key] = voice
        try? database.save(MeetingSpeaker(
            meetingId: meetingId, key: key, label: label, personId: voice.personId,
            assignment: isMe ? .confirmed : .unknown, channel: channel
        ))
    }

    /// Recognises a voice of the call against the library once there is enough of it.
    private func nameVoice(_ key: String) {
        guard var voice = voices[key], voice.personId == nil, voice.speech >= 3, let centroid = centroid(of: key) else { return }
        let me = people.values.first(where: \.isMe)?.id
        let matches = library.rank(centroid, excluding: me.map { [$0] } ?? [])
        guard let best = matches.first, best.similarity >= thresholds.automatic,
              best.similarity - (matches.dropFirst().first?.similarity ?? 0) >= thresholds.margin,
              let person = people[best.personId] else { return }
        voice.personId = person.id
        voice.name = person.name
        voices[key] = voice
        try? database.save(MeetingSpeaker(
            meetingId: meetingId, key: key, label: voice.label, personId: person.id, assignment: .automatic,
            confidence: Double(best.similarity), talkTime: voice.speech, channel: .system
        ))
    }

    /// Looks at the last lines for introductions and names, to offer "save as Paula".
    private func lookForNames() {
        let recentLines = lines.suffix(8).map { SpokenLine(speakerKey: $0.speakerKey, text: $0.text) }
        let finder = NameEvidenceFinder(knownNames: people.values.map(\.name))
        let guesses = NameEvidenceFinder.guesses(from: finder.clues(in: Array(recentLines)))
        for (key, keyGuesses) in guesses where key != MeetingSpeaker.meKey {
            guard var voice = voices[key], voice.personId == nil, let best = keyGuesses.first, best.score >= 1.2 else { continue }
            voice.suggestedName = resolve(best.name).name
            voices[key] = voice
        }
    }

    /// A spoken name as the app knows it: a person it knows ("Thomas" is Thomas Klein), the calendar's
    /// spelling of an invitee, or as said.
    private func resolve(_ spoken: String) -> (person: Person?, name: String, email: String?) {
        let identifier = SpeakerIdentifier(library: VoiceLibrary(), people: Array(people.values), attendees: attendees, thresholds: thresholds) { $0 }
        if let person = identifier.person(named: spoken) { return (person, person.name, person.email) }
        if let attendee = identifier.attendee(named: spoken) { return (nil, attendee.name, attendee.email) }
        return (nil, spoken, nil)
    }

    /// The user accepted a name for a live voice: remember the person and their voice right away.
    public func confirm(_ key: String, as name: String) {
        guard var voice = voices[key] else { return }
        let resolved = resolve(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !resolved.name.isEmpty else { return }
        let person: Person
        if let existing = resolved.person {
            person = existing
        } else {
            person = Person(name: resolved.name, email: resolved.email)
            try? database.save(person)
            people[person.id] = person
        }
        // Recognised from now on in this meeting; after it, the confirmed name carries over to the voice's
        // lines in the final transcript, and they teach the app the voice.
        if let centroid = centroid(of: key) {
            library.add(centroid, to: person.id, duration: voice.speech, meetingId: meetingId)
        }
        voice.personId = person.id
        voice.name = person.name
        voice.suggestedName = nil
        voices[key] = voice
        try? database.save(MeetingSpeaker(
            meetingId: meetingId, key: key, label: voice.label, personId: person.id, assignment: .confirmed,
            confidence: 1, talkTime: voice.speech, channel: .system
        ))
    }

    public func dismissSuggestion(for key: String) {
        voices[key]?.suggestedName = nil
    }

    public func displayName(for key: String) -> String {
        guard let voice = voices[key] else { return key == MeetingSpeaker.meKey ? Strings.me : key }
        return voice.name ?? Strings.label(voice.label)
    }

    // MARK: Markers

    @discardableResult
    public func addMarker(_ text: String) -> LiveMarker? {
        let time = clock.elapsed
        guard let marker = try? database.addMarker(Marker(meetingId: meetingId, time: time, text: text.trimmingCharacters(in: .whitespacesAndNewlines))) else { return nil }
        let live = LiveMarker(id: marker.id ?? 0, time: marker.time, text: marker.text)
        markers.append(live)
        return live
    }

    public func removeMarker(_ id: Int64) {
        try? database.deleteMarker(id)
        markers.removeAll { $0.id == id }
    }

    public func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.title = trimmed
        try? database.update(meetingId: meetingId) { meeting in
            meeting.title = trimmed
            meeting.titleIsCustom = true
        }
    }

    /// The transcript so far as plain text, for the live summary.
    public func transcriptText() -> String {
        lines.map { "[\(TimeFormat.clock($0.start))] \(displayName(for: $0.speakerKey)): \($0.text)" }.joined(separator: "\n")
    }
}

extension RecordingSession {
    /// For the demo mode's screenshots of the warnings.
    func showMicrophoneProblem(_ problem: MicrophoneProblem?) {
        microphoneProblem = problem
    }

    /// Fills the session with a made-up conversation, for the demo mode's screenshots.
    func loadDemoLines() {
        state = .recording
        elapsed = 754
        microphoneLevel = 0.12
        systemLevel = 0.64
        voices = [
            MeetingSpeaker.meKey: LiveVoice(key: MeetingSpeaker.meKey, label: Strings.meLabel, personId: "p-me", name: nil, suggestedName: nil, speech: 40),
            "S1": LiveVoice(key: "S1", label: Strings.speakerLabel(1), personId: "p-anna", name: "Anna Berger", suggestedName: nil, speech: 90),
            "S2": LiveVoice(key: "S2", label: Strings.speakerLabel(2), personId: "p-thomas", name: "Thomas Klein", suggestedName: nil, speech: 70),
            "S3": LiveVoice(key: "S3", label: Strings.speakerLabel(3), personId: "p-jonas", name: "Jonas Weber", suggestedName: nil, speech: 20),
            "S4": LiveVoice(key: "S4", label: Strings.speakerLabel(4), personId: nil, name: nil, suggestedName: "Paula", speech: 6),
        ]
        func line(_ id: String, _ key: String, _ start: Double, _ end: Double, _ text: String) -> LiveLine {
            LiveLine(id: id, speakerKey: key, channel: key == MeetingSpeaker.meKey ? .microphone : .system, start: start, end: end, text: text, isPartial: false)
        }
        lines = [
            line("1", "S1", 598, 606, "Dann zum Sprint-Ziel: Release 2.4 stabil bekommen. Mehr nehmen wir uns diesmal nicht vor."),
            line("2", "S2", 621, 628, "Dann sollten wir das Import-Ticket rausnehmen. Das ist zu groß für zwei Wochen."),
            line("3", MeetingSpeaker.meKey, 640, 646, "Einverstanden. Ich nehme den PDF-Export, das hängt ja sowieso an mir."),
            line("4", "S3", 675, 681, "Ich kann bei QA unterstützen, wenn Thomas mir die Testfälle schickt."),
            line("5", "S4", 708, 714, "Hallo zusammen, sorry für die Verspätung – hier ist Paula aus dem Support."),
        ]
        partials = [.system: LiveLine(id: "partial-system", speakerKey: "S2", channel: .system, start: 740, end: 740, text: "Willkommen, Paula. Wir sind gerade beim Sprint-Ziel und haben das Import-Ticket …", isPartial: true)]
        markers = [LiveMarker(id: 1, time: 662, text: "Budget für Testgeräte klären")]
        currentSpeakerKey = "S2"
    }
}
