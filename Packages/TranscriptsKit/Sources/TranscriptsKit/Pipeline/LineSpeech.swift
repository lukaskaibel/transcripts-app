import Foundation

/// Where in a line its voice is.
///
/// The speech model stretches the last word before a pause over the silence after it, so a line that says only
/// "Um," can last 13 seconds. A voice taken over all of that is mostly silence: short answers then sound alike and
/// unlike their speaker, and form a voice of their own. And the line plays, and counts as talk, for far longer than
/// it was spoken. The voice activity detector knows where the speech is: a line ends where its speech ends, and its
/// voice is taken from that speech only.
public enum LineSpeech {
    /// Speech that begins this long after the line's last word began is no longer that word: a laugh, a knock, someone
    /// else on the same channel the speech model left out.
    static let lastWordReach = 0.5
    /// A line never ends sooner than this after its last word began, even where the detector lost that word.
    static let shortestWord = 0.3
    /// Without word times (lines saved before lines were fitted), speech this much quieter (in dB) than the loudest of
    /// a line that comes after all of its louder speech is no longer the line: a breath, a click, the call's faint
    /// background. In the app's recordings such leftovers are 13–30 dB quieter, the quietest real words 12–15 dB.
    static let quieterThanLine: Float = 12

    /// The stretches of the channel's speech `regions` (sorted by time) that belong to the line from `start` to `end`.
    /// Without the time its last word began, everything heard in the line counts up to its last speech about as loud
    /// as the rest, judged on `samples` (the channel's audio).
    public static func parts(from start: Double, to end: Double, lastWordStart: Double? = nil, in regions: [ClosedRange<Double>], samples: [Float]? = nil) -> [ClosedRange<Double>] {
        let reach = min(end, (lastWordStart ?? end) + lastWordReach)
        var parts: [ClosedRange<Double>] = []
        // The first region that ends after the line starts; regions don't overlap, so their ends are sorted too.
        var lower = 0
        var upper = regions.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if regions[middle].upperBound <= start { lower = middle + 1 } else { upper = middle }
        }
        for region in regions[lower...] {
            guard region.lowerBound < reach else { break }
            let part = max(region.lowerBound, start)...min(region.upperBound, end)
            if part.upperBound > part.lowerBound { parts.append(part) }
        }
        if lastWordStart == nil, let samples, parts.count > 1 {
            let levels = parts.map { level(of: $0, in: samples) }
            let loudest = levels.max() ?? 0
            if let last = levels.lastIndex(where: { $0 >= loudest - quieterThanLine }) { parts = Array(parts[...last]) }
        }
        return parts
    }

    /// Where a line with these speech `parts` ends: where its speech does, never later than it did and never before its
    /// last word began. The line's own end when the detector heard nothing in it.
    public static func end(of parts: [ClosedRange<Double>], lineEnd: Double, lastWordStart: Double? = nil) -> Double {
        guard let last = parts.last else { return lineEnd }
        return min(lineEnd, max(last.upperBound, lastWordStart.map { $0 + shortestWord } ?? 0))
    }

    /// How much speech the parts hold, in seconds.
    public static func seconds(_ parts: [ClosedRange<Double>]) -> Double {
        parts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// The audio to take a line's voice from: its speech parts one after another, at most `limit` seconds of them.
    public static func audio(_ samples: [Float], parts: [ClosedRange<Double>], limit: Double = 20) -> [Float] {
        var result: [Float] = []
        let most = SpeechAudio.samples(limit)
        for part in parts where result.count < most {
            let lower = max(0, min(samples.count, SpeechAudio.samples(part.lowerBound)))
            let upper = max(lower, min(samples.count, SpeechAudio.samples(part.upperBound), lower + most - result.count))
            result += samples[lower..<upper]
        }
        return result
    }

    /// Where the line from `start` to `end` ends when fitted to the speech of its channel, and where its voice is. With no
    /// speech known for the channel, the line stays as it is and its voice is taken from all of it.
    public static func fit(from start: Double, to end: Double, lastWordStart: Double? = nil, in regions: [ClosedRange<Double>], samples: [Float]? = nil) -> (end: Double, parts: [ClosedRange<Double>]) {
        guard !regions.isEmpty, end > start else { return (end, end > start ? [start...end] : []) }
        let parts = parts(from: start, to: end, lastWordStart: lastWordStart, in: regions, samples: samples)
        return (self.end(of: parts, lineEnd: end, lastWordStart: lastWordStart), parts)
    }

    /// A line fitted to the speech of its channel (see `fit`); its last word ends with it.
    public static func fitted(_ line: DraftLine, to regions: [ClosedRange<Double>], samples: [Float]? = nil) -> (line: DraftLine, parts: [ClosedRange<Double>]) {
        let fit = fit(from: line.start, to: line.end, lastWordStart: line.words.last?.start, in: regions, samples: samples)
        var result = line
        result.end = fit.end
        for index in result.words.indices where result.words[index].end > result.end {
            result.words[index].end = max(result.words[index].start, result.end)
        }
        return (result, fit.parts)
    }

    /// The loudness of a stretch of `samples`, in dBFS.
    static func level(of part: ClosedRange<Double>, in samples: [Float]) -> Float {
        let lower = max(0, min(samples.count, SpeechAudio.samples(part.lowerBound)))
        let upper = max(lower, min(samples.count, SpeechAudio.samples(part.upperBound)))
        return 20 * log10(max(SpeechAudio.rms(samples[lower..<upper]), 1e-7))
    }
}
