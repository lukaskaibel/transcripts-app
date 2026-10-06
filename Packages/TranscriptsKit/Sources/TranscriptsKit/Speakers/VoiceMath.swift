import Accelerate
import Foundation

/// Arithmetic on voice embeddings (256-dimensional vectors from the WeSpeaker model).
public enum VoiceMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 1e-9 else { return vector }
        var scale = 1 / norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine similarity in -1...1. Vectors of different length are treated as unrelated.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 1e-9 else { return 0 }
        return dot / denominator
    }

    /// The weighted average direction of several embeddings, normalised.
    public static func weightedMean(_ items: [([Float], Float)]) -> [Float]? {
        guard let dimension = items.first?.0.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var totalWeight: Float = 0
        for (vector, weight) in items where vector.count == dimension && weight > 0 {
            let unit = normalized(vector)
            var w = weight
            vDSP_vsma(unit, 1, &w, sum, 1, &sum, 1, vDSP_Length(dimension))
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return normalized(sum)
    }
}

/// How sure the app must be before it names a voice by itself.
public struct VoiceThresholds: Equatable, Sendable {
    /// Assign without asking.
    public var automatic: Float
    /// Propose, and wait for the user's click.
    public var suggestion: Float
    /// The best person must lead the runner-up by this much to be assigned automatically.
    public var margin: Float
    /// Two stretches of speech in one meeting belong to the same voice above this.
    public var sameSpeaker: Float

    public init(automatic: Float, suggestion: Float, margin: Float, sameSpeaker: Float) {
        self.automatic = automatic
        self.suggestion = suggestion
        self.margin = margin
        self.sameSpeaker = sameSpeaker
    }

    public static let standard = VoiceThresholds(automatic: 0.72, suggestion: 0.55, margin: 0.08, sameSpeaker: 0.5)
    public static let strict = VoiceThresholds(automatic: 0.8, suggestion: 0.62, margin: 0.12, sameSpeaker: 0.55)
    public static let relaxed = VoiceThresholds(automatic: 0.66, suggestion: 0.48, margin: 0.05, sameSpeaker: 0.45)
}

/// A known person's voice compared with an unknown one.
public struct VoiceMatch: Equatable, Sendable {
    public var personId: String
    public var similarity: Float
    /// How many stored samples of this person there are; more samples make a match more trustworthy.
    public var samples: Int
}

/// Compares voices against everyone the app has heard before.
public struct VoiceLibrary: Sendable {
    /// Stored embeddings per person.
    public private(set) var voices: [String: [[Float]]]

    public init(voices: [String: [[Float]]] = [:]) {
        self.voices = voices
    }

    public init(voiceprints: [Voiceprint]) {
        var voices: [String: [[Float]]] = [:]
        for print in voiceprints {
            voices[print.personId, default: []].append([Float](embeddingData: print.embedding))
        }
        self.voices = voices
    }

    public var isEmpty: Bool { voices.isEmpty }

    public mutating func add(_ embedding: [Float], to personId: String) {
        voices[personId, default: []].append(embedding)
    }

    /// Everyone ranked by similarity, best first.
    ///
    /// A person's score is the mean of their two best matching samples (or the single one), which
    /// is steadier than the maximum when someone has many recordings from different microphones.
    /// People in `boosted` (for example the invitees of the calendar event) get a small head start.
    public func rank(_ embedding: [Float], boosted: Set<String> = [], excluding: Set<String> = []) -> [VoiceMatch] {
        voices.compactMap { personId, samples -> VoiceMatch? in
            guard !excluding.contains(personId), !samples.isEmpty else { return nil }
            let scores = samples.map { VoiceMath.cosine(embedding, $0) }.sorted(by: >)
            var score = scores.count >= 2 ? (scores[0] + scores[1]) / 2 : scores[0]
            score = max(score, scores[0] - 0.05)
            // Invitees get a small head start; the score may then exceed 1, which only matters for the order.
            if boosted.contains(personId) { score += 0.04 }
            return VoiceMatch(personId: personId, similarity: score, samples: samples.count)
        }
        .sorted { $0.similarity > $1.similarity }
    }
}

/// Groups utterances of one live recording by voice, as they come in.
public struct LiveSpeakerTracker: Sendable {
    public struct Voice: Sendable {
        public var key: String
        public var centroid: [Float]
        public var speech: Double
    }

    public private(set) var voices: [Voice] = []
    public var threshold: Float

    public init(threshold: Float = VoiceThresholds.standard.sameSpeaker) {
        self.threshold = threshold
    }

    /// The key ("S1", "S2", …) of the voice this embedding belongs to, starting a new one if nobody fits.
    public mutating func assign(_ embedding: [Float], duration: Double) -> String {
        let scored = voices.enumerated().map { ($0.offset, VoiceMath.cosine(embedding, $0.element.centroid)) }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= threshold {
            var voice = voices[best.0]
            // A running average that trusts long stretches more than short ones.
            let weight = Float(min(duration, 10) / max(voice.speech + duration, 1))
            voice.centroid = VoiceMath.weightedMean([(voice.centroid, 1 - weight), (embedding, weight)]) ?? voice.centroid
            voice.speech += duration
            voices[best.0] = voice
            return voice.key
        }
        let key = "S\(voices.count + 1)"
        voices.append(Voice(key: key, centroid: VoiceMath.normalized(embedding), speech: duration))
        return key
    }

    public func centroid(of key: String) -> [Float]? {
        voices.first { $0.key == key }?.centroid
    }
}
