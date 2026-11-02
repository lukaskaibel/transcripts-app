import Accelerate
import AVFoundation
import Foundation

/// Where in a line's time its voice actually is. The speech model stretches the last word before a pause over the
/// silence after it, so a line that says only "Ähm," can last 13 seconds; played whole, it is mostly silence or,
/// with both channels, the other side talking.
public enum AudibleSpan {
    /// Quieter than this is no voice, whatever else the line holds.
    static let floor: Float = -50
    /// A window counts as the voice when it is at most this much quieter than the loudest one in the line.
    static let belowLoudest: Float = 28
    static let window = 0.05
    /// Loud windows this close together (in windows) are one stretch: the pauses inside a word or between words.
    static let joinedWithin = 5
    /// A stretch shorter than this (in windows) is a click or a knock, not a word.
    static let shortest = 4

    /// `range` narrowed to where `file` is loud enough to be speech, with a little air before and after. The whole
    /// range when the file can't be read there or is quiet throughout.
    public static func of(_ range: ClosedRange<Double>, in file: URL) -> ClosedRange<Double> {
        guard let levels = levels(of: range, in: file), let span = span(levels: levels) else { return range }
        let start = max(range.lowerBound, range.lowerBound + span.lowerBound - 0.15)
        let end = min(range.upperBound, range.lowerBound + span.upperBound + 0.35)
        return end > start ? start...end : range
    }

    /// The seconds, from the start of the levels, from the first stretch loud enough to be the voice to the last.
    static func span(levels: [Float]) -> ClosedRange<Double>? {
        guard let loudest = levels.max(), loudest > floor, let peak = levels.firstIndex(of: loudest) else { return nil }
        let threshold = max(floor, loudest - belowLoudest)
        var stretches: [ClosedRange<Int>] = []
        for (index, level) in levels.enumerated() where level >= threshold {
            if let last = stretches.last, index - last.upperBound <= joinedWithin {
                stretches[stretches.count - 1] = last.lowerBound...index
            } else {
                stretches.append(index...index)
            }
        }
        let voiced = stretches.filter { $0.count >= shortest }
        // Nothing as long as a word: the loudest bit, whatever it is.
        let kept = voiced.isEmpty ? stretches.filter { $0.contains(peak) } : voiced
        guard let first = kept.first, let last = kept.last else { return nil }
        return Double(first.lowerBound) * window...Double(last.upperBound + 1) * window
    }

    /// Loudness in dBFS of each 50 ms of the range, from the file's first channel.
    static func levels(of range: ClosedRange<Double>, in url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, range.lowerBound) * rate)
        guard first < file.length else { return nil }
        let count = AVAudioFrameCount(min(Double(file.length - first), (range.upperBound - range.lowerBound) * rate))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: count)) != nil,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let size = max(1, Int(rate * window))
        let total = Int(buffer.frameLength)
        return stride(from: 0, to: total, by: size).map { start in
            var rms: Float = 0
            vDSP_rmsqv(samples + start, 1, &rms, vDSP_Length(min(size, total - start)))
            return 20 * log10(max(rms, 1e-7))
        }
    }
}
