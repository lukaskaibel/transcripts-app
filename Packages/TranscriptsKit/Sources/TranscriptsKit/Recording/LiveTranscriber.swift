import FluidAudio
import Foundation

/// Something the live transcriber noticed.
public enum LiveEvent: Sendable {
    /// The current utterance so far; replaced by the next partial or the final.
    case partial(channel: Channel, start: Double, text: String)
    /// A finished utterance. `speaker` is the live diarizer's voice ID and `embedding` its voice so far,
    /// `voice` the voice of just this utterance; all for call audio only.
    case final(channel: Channel, start: Double, end: Double, text: String, speaker: String?, embedding: [Float]?, voice: [Float]?)
    /// The channel went quiet; any partial can be cleared.
    case silence(channel: Channel)
}

/// Transcribes one channel while it is being recorded.
///
/// A voice activity detector cuts the stream into utterances. While someone talks, the growing
/// utterance is transcribed every second and a half for a live preview; when they stop, the whole
/// utterance is transcribed once more and reported as final.
public actor LiveTranscriber {
    public let channel: Channel
    private let engine: SpeechEngine
    private let onEvent: @Sendable (LiveEvent) -> Void

    private static let block = 4096
    private static let keepSeconds = 40.0
    private static let maxUtterance = 12.0
    private static let partialInterval = 1.5

    private let vadConfig = VadSegmentationConfig(minSpeechDuration: 0.2, minSilenceDuration: 0.3, maxSpeechDuration: 12, speechPadding: 0.12)
    private var diarizer: LiveDiarizer?
    private var diarizerRequested = false
    private var vadState: VadStreamState?
    private var pending: [Float] = []
    /// The last `keepSeconds` of audio, starting at absolute sample `recentStart`.
    private var recent: [Float] = []
    private var recentStart = 0
    private var processed = 0
    private var utteranceStart: Int?
    private var lastPartialAt = 0
    private var partialTask: Task<Void, Never>?

    public init(channel: Channel, engine: SpeechEngine = .shared, onEvent: @escaping @Sendable (LiveEvent) -> Void) {
        self.channel = channel
        self.engine = engine
        self.onEvent = onEvent
    }

    /// Feeds 16 kHz mono samples in recording order.
    public func feed(_ samples: [Float]) async {
        pending += samples
        while pending.count >= Self.block {
            let block = Array(pending.prefix(Self.block))
            pending.removeFirst(Self.block)
            await process(block)
        }
    }

    /// Flushes the utterance in progress, for when the recording stops or pauses.
    public func finish() async {
        if let start = utteranceStart {
            await finalize(from: start, to: processed)
        }
        utteranceStart = nil
        pending.removeAll()
    }

    private func process(_ block: [Float]) async {
        recent += block
        processed += block.count
        trimRecent()

        if vadState == nil { vadState = try? await engine.makeVadState() }
        guard let state = vadState,
              let result = try? await engine.detectSpeech(block, state: state, config: vadConfig) else { return }
        vadState = result.state

        if let event = result.event {
            switch event.kind {
            case .speechStart:
                if utteranceStart == nil {
                    utteranceStart = max(recentStart, event.sampleIndex)
                    lastPartialAt = processed
                }
            case .speechEnd:
                if let start = utteranceStart {
                    utteranceStart = nil
                    await finalize(from: start, to: max(start, min(processed, event.sampleIndex)))
                }
            }
        }

        guard let start = utteranceStart else { return }
        if SpeechAudio.seconds(processed - start) >= Self.maxUtterance {
            // A long monologue: close this piece at the quietest moment of the last seconds (between
            // two words; a piece that starts mid-word makes the speech model drop its first sentence)
            // and carry on with a new one.
            let split = quietestPoint(from: max(start + SpeechAudio.samples(4), processed - SpeechAudio.samples(4)), to: processed - SpeechAudio.samples(0.2))
            await finalize(from: start, to: split)
            utteranceStart = split
            lastPartialAt = processed
        } else if SpeechAudio.seconds(processed - lastPartialAt) >= Self.partialInterval {
            lastPartialAt = processed
            schedulePartial(from: start)
        }
    }

    private func schedulePartial(from start: Int) {
        // Never queue partials behind each other; skip one if the last is still running.
        guard partialTask == nil else { return }
        let audio = audio(from: start, to: processed)
        let channel = channel
        let startTime = SpeechAudio.seconds(start)
        partialTask = Task { [engine, onEvent] in
            if let text = try? await engine.transcribe(audio).text, !text.isEmpty {
                onEvent(.partial(channel: channel, start: startTime, text: text))
            }
            self.partialDone()
        }
    }

    private func partialDone() {
        partialTask = nil
    }

    private func finalize(from start: Int, to end: Int) async {
        partialTask?.cancel()
        partialTask = nil
        let audio = audio(from: start, to: end)
        guard SpeechAudio.seconds(audio.count) >= 0.3 else {
            onEvent(.silence(channel: channel))
            return
        }
        guard let transcription = try? await engine.transcribe(audio), !transcription.text.isEmpty else {
            onEvent(.silence(channel: channel))
            return
        }
        let startTime = SpeechAudio.seconds(start)
        guard channel == .system else {
            // The microphone's own voice, to notice the call coming back through the speakers.
            let voice = SpeechAudio.seconds(audio.count) >= 1.5 ? try? await engine.voiceEmbedding(audio[...]) : nil
            onEvent(.final(channel: channel, start: startTime, end: SpeechAudio.seconds(end), text: transcription.text, speaker: nil, embedding: nil, voice: voice))
            return
        }
        if !diarizerRequested {
            diarizerRequested = true
            diarizer = await engine.makeLiveDiarizer()
        }
        // Split the utterance where the voice changes, and name each piece's voice.
        let words = transcription.words.map { TimedWord(text: $0.text, start: $0.start + startTime, end: $0.end + startTime) }
        let turns = await diarizer?.turns(in: audio, at: startTime) ?? []
        guard !turns.isEmpty, !words.isEmpty else {
            let embedding = SpeechAudio.seconds(audio.count) >= 1.0 ? try? await engine.voiceEmbedding(audio[...]) : nil
            onEvent(.final(channel: channel, start: startTime, end: SpeechAudio.seconds(end), text: transcription.text, speaker: nil, embedding: embedding, voice: embedding))
            return
        }
        let speakers = TranscriptAssembly.speakers(for: words, turns: turns)
        for line in TranscriptAssembly.lines(words: words, speakers: speakers, channel: .system) {
            let embedding = await diarizer?.embedding(of: line.speakerKey)
            // The line's own voice, so the session can check it against the people it knows.
            var voice: [Float]?
            if line.end - line.start >= 1.5 {
                let lower = max(0, min(audio.count, SpeechAudio.samples(line.start - startTime)))
                let upper = max(lower, min(audio.count, SpeechAudio.samples(line.end - startTime)))
                voice = try? await engine.voiceEmbedding(audio[lower..<upper])
            }
            onEvent(.final(channel: channel, start: line.start, end: line.end, text: line.text, speaker: line.speakerKey, embedding: embedding, voice: voice))
        }
    }

    /// The middle of the quietest 100 ms window between `from` and `to` (absolute samples).
    private func quietestPoint(from: Int, to: Int) -> Int {
        let window = SpeechAudio.samples(0.1)
        let hop = SpeechAudio.samples(0.02)
        guard to - from > window else { return to }
        var best = (position: to, energy: Float.greatestFiniteMagnitude)
        var position = from
        while position + window <= to {
            let lower = position - recentStart
            guard lower >= 0, lower + window <= recent.count else { position += hop; continue }
            let energy = SpeechAudio.rms(recent[lower..<(lower + window)])
            if energy < best.energy { best = (position + window / 2, energy) }
            position += hop
        }
        return best.position
    }

    private func audio(from start: Int, to end: Int) -> [Float] {
        let lower = max(0, start - recentStart)
        let upper = max(lower, min(recent.count, end - recentStart))
        return Array(recent[lower..<upper])
    }

    private func trimRecent() {
        let keep = SpeechAudio.samples(Self.keepSeconds)
        guard recent.count > keep * 2 else { return }
        var drop = recent.count - keep
        if let start = utteranceStart {
            drop = min(drop, max(0, start - recentStart))
        }
        guard drop > 0 else { return }
        recent.removeFirst(drop)
        recentStart += drop
    }
}
