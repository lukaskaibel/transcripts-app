import Accelerate
import Foundation

/// Sorts the words heard on the microphone into the user's and what is left of the call's echo.
///
/// The echo suppressor turns the call down by 20–40 dB and leaves the user's voice as it was; but the
/// speech model still makes words out of what is left, and those used to land in the user's lines. So each
/// word is judged by two things: how much quieter the cleaning made it (the user's words lose next to
/// nothing, echo loses a lot), and how loud it still is next to the user's own speaking level (measured
/// on words spoken while the call was silent). Quiet words in the middle of the user's sentences stay.
public enum MicrophoneWords {
    /// Loudness is measured in frames of 20 ms.
    static let frame = 320

    /// The level of every 20 ms of a track, in dB.
    public static func levels(_ samples: [Float]) -> [Float] {
        let count = samples.count / frame
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { values in
            for index in 0..<count {
                var square: Float = 0
                vDSP_measqv(values.baseAddress! + index * frame, 1, &square, vDSP_Length(frame))
                result[index] = 10 * log10(square + 1e-18)
            }
        }
        return result
    }

    /// The user's words among `words`, given the levels of the cleaned and the raw microphone and of the call.
    public static func own(_ words: [TimedWord], cleaned: [Float], raw: [Float], call: [Float]) -> [TimedWord] {
        guard !words.isEmpty, !cleaned.isEmpty else { return words }
        func peak(_ levels: [Float], _ word: TimedWord) -> Float {
            let lower = max(0, min(levels.count - 1, Int(SpeechAudio.samples(word.start) / frame)))
            let upper = max(lower + 1, min(levels.count, Int((SpeechAudio.samples(word.end) + frame - 1) / frame)))
            return levels[lower..<upper].max() ?? -180
        }
        let clean = words.map { peak(cleaned, $0) }
        let removed = words.indices.map { peak(raw, words[$0]) - clean[$0] }
        let callLevel = words.map { call.isEmpty ? -180 : peak(call, $0) }

        // How loud the user speaks: their words while the call was silent.
        let alone = words.indices.filter { callLevel[$0] < -45 && clean[$0] > -50 }.map { clean[$0] }.sorted()
        let reference: Float
        if alone.count >= 10 {
            reference = alone[alone.count / 2]
        } else {
            let all = clean.sorted()
            reference = all[min(all.count - 1, Int(Double(all.count) * 0.9))]
        }

        let user = words.indices.map { index in
            clean[index] >= reference - 18 && (removed[index] <= 8 || (clean[index] >= reference - 6 && removed[index] <= 15))
        }
        func middle(_ index: Int) -> Double { (words[index].start + words[index].end) / 2 }
        var keep = user
        for index in words.indices where !user[index] && removed[index] <= 8 && clean[index] >= reference - 30 {
            // Soft, but right next to the user speaking.
            let neighbours = max(0, index - 4)...min(words.count - 1, index + 4)
            if neighbours.contains(where: { user[$0] && abs(middle($0) - middle(index)) <= 0.6 }) { keep[index] = true }
        }
        // A word between two kept ones close together belongs to the sentence.
        for index in words.indices where !keep[index] && removed[index] <= 12 {
            guard let before = (max(0, index - 3)..<index).reversed().first(where: { keep[$0] }),
                  let after = ((index + 1)..<min(words.count, index + 4)).first(where: { keep[$0] }) else { continue }
            if words[after].start - words[before].end <= 1.5 { keep[index] = true }
        }
        return words.indices.filter { keep[$0] }.map { words[$0] }
    }
}
