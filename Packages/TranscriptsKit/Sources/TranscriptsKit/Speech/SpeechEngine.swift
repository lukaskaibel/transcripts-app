import CoreML
import FluidAudio
import Foundation

/// The speech-to-text model variants the app offers.
public enum TranscriptionModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case ultra
    case v3
    case redux

    public var id: String { rawValue }

    var version: AsrModelVersion {
        switch self {
        case .ultra: .ultra
        case .v3: .v3
        case .redux: .redux
        }
    }

    public var title: String {
        switch self {
        case .ultra: "Parakeet Ultra"
        case .v3: "Parakeet v3"
        case .redux: "Parakeet Redux"
        }
    }

    public var detail: String {
        switch self {
        case .ultra: String(localized: "Am genauesten, empfohlen · ca. 650 MB")
        case .v3: String(localized: "Der bewährte Vorgänger · ca. 480 MB")
        case .redux: String(localized: "Kleiner, etwas ungenauer · ca. 220 MB")
        }
    }

    public var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Removes this model's files from disk.
    public func deleteFiles() throws {
        let folder = AsrModels.defaultCacheDirectory(for: version)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }
}

/// A word with its position in the audio.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Transcription: Sendable {
    public var text: String
    public var words: [TimedWord]
}

/// Who spoke when, plus each voice's embedding.
public struct SpeakerTurn: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
}

public struct Diarization: Sendable {
    public var turns: [SpeakerTurn]
}

/// Where model preparation stands, for the onboarding and settings screens.
public enum SpeechEngineState: Equatable, Sendable {
    case idle
    case preparing(step: String, fraction: Double)
    case ready
    case failed(String)
}

/// Owns the on-device models: Parakeet for speech, Silero for voice activity, pyannote/WeSpeaker for voices.
///
/// Everything runs on the Neural Engine. Models are downloaded from Hugging Face on first use and then
/// load from disk in a second or two.
public actor SpeechEngine {
    public static let shared = SpeechEngine()

    private var asr: AsrManager?
    private var loadedModel: TranscriptionModel?
    private var vad: VadManager?
    private var embedder: DiarizerManager?
    private var diarizerModels: DiarizerModels?
    private var diarizer: OfflineDiarizerManager?
    private var offlineModels: OfflineDiarizerModels?
    private var preparing: Task<Void, Error>?

    public init() {}

    public var isReady: Bool { asr != nil && vad != nil && embedder != nil && diarizer != nil }
    public var currentModel: TranscriptionModel? { loadedModel }

    /// Downloads (if needed) and loads every model. Safe to call repeatedly; concurrent calls share one load.
    public func prepare(model: TranscriptionModel, progress: (@Sendable (SpeechEngineState) -> Void)? = nil) async throws {
        if isReady, loadedModel == model {
            progress?(.ready)
            return
        }
        if let preparing {
            try await preparing.value
            if loadedModel == model, isReady { return }
        }
        let task = Task { try await self.load(model: model, progress: progress) }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func load(model: TranscriptionModel, progress: (@Sendable (SpeechEngineState) -> Void)?) async throws {
        let report: @Sendable (String, Double) -> Void = { step, fraction in
            progress?(.preparing(step: step, fraction: min(max(fraction, 0), 1)))
        }
        do {
            if asr == nil || loadedModel != model {
                report(String(localized: "Spracherkennung", comment: "step while preparing: the speech-to-text model"), 0)
                let models = try await AsrModels.downloadAndLoad(version: model.version) { update in
                    report(String(localized: "Spracherkennung", comment: "step while preparing: the speech-to-text model"), update.fractionCompleted * 0.8)
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
                loadedModel = model
            }
            if vad == nil {
                report(String(localized: "Spracherkennung", comment: "step while preparing: the speech-to-text model"), 0.82)
                vad = try await VadManager(config: VadConfig(defaultThreshold: 0.6))
            }
            if embedder == nil {
                report(String(localized: "Stimmerkennung", comment: "step while preparing: the model that recognises voices"), 0.85)
                let models = try await DiarizerModels.downloadIfNeeded { update in
                    report(String(localized: "Stimmerkennung", comment: "step while preparing: the model that recognises voices"), 0.85 + update.fractionCompleted * 0.07)
                }
                let manager = DiarizerManager()
                diarizerModels = models
                manager.initialize(models: models)
                embedder = manager
            }
            if diarizer == nil {
                report(String(localized: "Sprechertrennung", comment: "step while preparing: the model that tells apart who speaks when"), 0.92)
                let models = try await OfflineDiarizerModels.load { update in
                    report(String(localized: "Sprechertrennung", comment: "step while preparing: the model that tells apart who speaks when"), 0.92 + update.fractionCompleted * 0.08)
                }
                let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
                manager.initialize(models: models)
                diarizer = manager
                offlineModels = models
            }
            progress?(.ready)
        } catch {
            progress?(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Frees the models' memory, for example after the transcription model was switched.
    public func unload() {
        asr = nil
        loadedModel = nil
    }

    // MARK: Speech to text

    /// Transcribes 16 kHz mono samples of any length.
    public func transcribe(_ samples: [Float]) async throws -> Transcription {
        guard let asr else { throw SpeechError.notReady }
        let minimum = SpeechAudio.samples(1.0)
        var input = samples
        if input.count < minimum {
            // Very short clips are padded with silence; the model rejects anything under 0.3 s.
            input += [Float](repeating: 0, count: minimum - input.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(input, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, words: words)
    }

    // MARK: Voice activity

    public func makeVadState() async throws -> VadStreamState {
        guard let vad else { throw SpeechError.notReady }
        return await vad.makeStreamState()
    }

    /// Runs one 4096-sample block (256 ms) through the voice activity detector.
    public func detectSpeech(_ block: [Float], state: VadStreamState, config: VadSegmentationConfig) async throws -> VadStreamResult {
        guard let vad else { throw SpeechError.notReady }
        return try await vad.processStreamingChunk(block, state: state, config: config)
    }

    /// Stretches of speech in a whole recording.
    public func speechRegions(in samples: [Float]) async throws -> [ClosedRange<Double>] {
        guard let vad else { throw SpeechError.notReady }
        let segments = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.5))
        return segments.map { $0.startTime...$0.endTime }
    }

    // MARK: Voices

    /// A 256-dimensional, L2-normalised embedding of one speaker's voice.
    ///
    /// The model looks at 10 s at a time; longer clips are cut into windows whose embeddings are averaged.
    public func voiceEmbedding(_ samples: ArraySlice<Float>) throws -> [Float]? {
        guard let embedder else { throw SpeechError.notReady }
        let window = SpeechAudio.samples(10)
        guard samples.count >= SpeechAudio.samples(0.8) else { return nil }
        var embeddings: [([Float], Float)] = []
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + window, samples.endIndex)
            // A short tail after full windows adds little; skip it.
            if end - start < SpeechAudio.samples(2), !embeddings.isEmpty { break }
            let slice = Array(samples[start..<end])
            let embedding = try embedder.extractSpeakerEmbedding(from: slice)
            if embedder.validateEmbedding(embedding) {
                embeddings.append((embedding, Float(end - start)))
            }
            start = end
        }
        return VoiceMath.weightedMean(embeddings)
    }

    /// A diarizer for one live recording, which keeps its voices apart across the whole session.
    public func makeLiveDiarizer() -> LiveDiarizer? {
        diarizerModels.map { LiveDiarizer(models: $0) }
    }

    // MARK: Who spoke when

    /// Who spoke when. `threshold` is the clustering cut (lower finds more voices); `minSpeakers`
    /// forces at least that many voices when the meeting is known to have them.
    public func diarize(_ samples: [Float], threshold: Double? = nil, minSpeakers: Int? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Diarization {
        guard var diarizer else { throw SpeechError.notReady }
        guard samples.count >= SpeechAudio.samples(2) else { return Diarization(turns: []) }
        if threshold != nil || minSpeakers != nil, let models = offlineModels {
            var config = OfflineDiarizerConfig()
            if let threshold { config.clustering.threshold = threshold }
            config.clustering.minSpeakers = minSpeakers
            let custom = OfflineDiarizerManager(config: config)
            custom.initialize(models: models)
            diarizer = custom
        }
        let result = try await diarizer.process(audio: samples) { done, total in
            progress?(total > 0 ? Double(done) / Double(total) : 0)
        }
        let turns = result.segments
            .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        return Diarization(turns: turns)
    }
}

public enum SpeechError: LocalizedError {
    case notReady
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .notReady: String(localized: "Die Sprachmodelle sind noch nicht geladen.")
        case .noAudio: String(localized: "Die Aufnahme enthält kein Audio.")
        }
    }
}

/// Separates voices while a meeting is recorded: each finished utterance is split where the voice
/// changes, with speaker IDs that stay the same for the whole session.
public actor LiveDiarizer {
    private let manager: DiarizerManager

    init(models: DiarizerModels) {
        manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.7, minSpeechDuration: 0.4, minSilenceGap: 0.3))
        manager.initialize(models: models)
    }

    /// Who spoke when within `samples`, which start at `start` seconds into the recording.
    public func turns(in samples: [Float], at start: Double) -> [SpeakerTurn] {
        guard samples.count >= SpeechAudio.samples(0.5),
              let result = try? manager.performCompleteDiarization(samples, atTime: start) else { return [] }
        return result.segments
            .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }

    /// The voice of a speaker as learned so far in this session.
    public func embedding(of speaker: String) -> [Float]? {
        manager.speakerManager.getSpeaker(for: speaker)?.currentEmbedding
    }
}
