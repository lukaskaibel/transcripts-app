import Accelerate
import AVFoundation
import Foundation

/// Repairs call tracks recorded before the app read the system audio at the output device's own rate.
///
/// On a Mac whose speakers run at 44.1 kHz, the tap's buffers were read as 48 kHz: the call came out 9 %
/// too fast and too high, and to keep up with the clock the recording padded in half a second of exact
/// silence about every six seconds. Between two such gaps the audio is complete, only squeezed; so each
/// piece is stretched back to its real length and put where it belongs.
public enum CallTrackRepair {
    public struct Damage: Equatable, Sendable {
        /// Recorded speed: samples the device delivered per sample assumed (44.1 / 48).
        public var ratio: Double
        public var gaps: Int
    }

    static let rates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
    /// Exact silence is what the recording padded in; a decoded compressed file keeps it below this.
    static let silence: Float = 3e-5

    /// The damage, if the track shows its signature: gaps of exact silence of about half a second (the
    /// recording padded in what it had fallen behind, as soon as that passed half a second), coming at the
    /// regular pace a wrong rate makes them, all through the recording, and adding up to the share of samples
    /// that rate loses. A call app's own digital silence comes in all lengths and at no pace, and is left alone.
    public static func damage(in samples: [Float]) -> Damage? {
        let seconds = SpeechAudio.seconds(samples.count)
        guard seconds >= 30 else { return nil }
        let runs = silentRuns(samples, minimum: SpeechAudio.samples(0.05))
        let gaps = runs.filter { (0.3...1.2).contains(SpeechAudio.seconds($0.count)) }
        guard gaps.count >= 5 else { return nil }
        let halfSecond = gaps.filter { (0.35...0.85).contains(SpeechAudio.seconds($0.count)) }
        guard Double(halfSecond.count) >= Double(gaps.count) * 0.9 else { return nil }
        let missing = gaps.reduce(0.0) { $0 + SpeechAudio.seconds($1.count) } / seconds
        // The ratio whose loss matches what is missing.
        var best: (ratio: Double, error: Double)?
        for actual in rates {
            for assumed in rates where actual < assumed {
                let ratio = actual / assumed
                let error = abs((1 - ratio) - missing)
                if error < 0.02, error < (best?.error ?? .infinity) { best = (ratio, error) }
            }
        }
        guard let ratio = best?.ratio else { return nil }
        // The pace: one gap per `expected` seconds; a gap that fell into a pause leaves a double step.
        let expected = 0.5 / (1 / ratio - 1) + 0.5
        guard Double(gaps.count) >= seconds / expected * 0.5 else { return nil }
        let steps = zip(gaps, gaps.dropFirst()).map { SpeechAudio.seconds($1.lowerBound - $0.lowerBound) / expected }
        let sorted = steps.sorted()
        guard (0.85...1.15).contains(sorted[sorted.count / 2]) else { return nil }
        let onPace = steps.filter { step in [1.0, 2, 3].contains { abs(step - $0) <= 0.25 } }
        guard Double(onPace.count) >= Double(steps.count) * 0.55 else { return nil }
        return Damage(ratio: ratio, gaps: gaps.count)
    }

    /// The track at its real speed, the padding gone and every piece back at its time. With the microphone
    /// of the same meeting, pieces whose echo it caught are put exactly where the echo says.
    public static func repair(_ samples: [Float], ratio: Double, echo microphone: [Float]? = nil) -> [Float] {
        let runs = silentRuns(samples, minimum: SpeechAudio.samples(0.05))
        // How far the recording ran ahead of the clock since it last caught up, in seconds.
        var behind = 0.0
        var cursor = 0
        var pieces: [(samples: [Float], start: Int)] = []
        for run in runs + [samples.count..<samples.count] {
            if run.lowerBound > cursor {
                let stretched = SpeechAudio.resample(Array(samples[cursor..<run.lowerBound]), from: SpeechAudio.sampleRate * ratio, to: SpeechAudio.sampleRate)
                pieces.append((stretched, SpeechAudio.samples(SpeechAudio.seconds(cursor) + behind)))
                behind += SpeechAudio.seconds(run.lowerBound - cursor) * (1 / ratio - 1)
            }
            let gap = SpeechAudio.seconds(run.count)
            if gap >= 0.3, behind + gap * (1 / ratio - 1) >= 0.35 {
                // The padding is in this silence: the recording caught up with the clock here.
                behind = 0
            } else {
                behind += gap * (1 / ratio - 1)
            }
            cursor = run.upperBound
        }
        if let microphone { pieces = aligned(pieces, to: microphone) }
        var output = [Float](repeating: 0, count: samples.count)
        for piece in pieces where piece.start < output.count {
            let start = max(0, piece.start)
            let skip = start - piece.start
            let end = min(output.count, piece.start + piece.samples.count)
            guard end > start else { continue }
            output.replaceSubrange(start..<end, with: piece.samples[skip..<(skip + end - start)])
        }
        return output
    }

    /// The padding was decided when the recording got round to a piece, which could be a moment after it
    /// arrived; so a piece can sit up to a few hundred milliseconds late. Through speakers the microphone
    /// heard each piece at its real time (plus the room's delay, the same for all), which shows where it goes.
    static func aligned(_ pieces: [(samples: [Float], start: Int)], to microphone: [Float]) -> [(samples: [Float], start: Int)] {
        let decimation = 4
        let mic = EchoSuppressor.decimated(microphone, by: decimation, count: microphone.count)
        let maxLag = SpeechAudio.samples(0.8) / decimation
        let longest = SpeechAudio.samples(8) / decimation
        let size = 1 << 16
        let fft = RealFFT(count: size)
        var a = [Float](repeating: 0, count: size)
        var b = [Float](repeating: 0, count: size)
        var lags: [Int?] = []
        for piece in pieces {
            let content = EchoSuppressor.decimated(piece.samples, by: decimation, count: min(piece.samples.count, longest * decimation))
            let start = piece.start / decimation
            guard content.count >= SpeechAudio.samples(1) / decimation, start + content.count + maxLag <= mic.count,
                  SpeechAudio.rms(content) >= 0.005 else {
                lags.append(nil)
                continue
            }
            vDSP.fill(&a, with: 0)
            vDSP.fill(&b, with: 0)
            // The first piece starts with the recording; the microphone before it is silence.
            let from = max(0, start - maxLag)
            let lead = from - (start - maxLag)
            a.replaceSubrange(lead..<(content.count + 2 * maxLag), with: mic[from..<(start + content.count + maxLag)])
            b.replaceSubrange(0..<content.count, with: content)
            let correlation = Array(fft.phaseCorrelation(a, b)[0..<(2 * maxLag)])
            let (index, peak) = vDSP.indexOfMaximum(correlation)
            lags.append(peak / max(vDSP.meanMagnitude(correlation), 1e-12) > 12 ? (Int(index) - maxLag) * decimation : nil)
        }
        let found = lags.compactMap { $0 }.sorted()
        guard found.count >= 5 else { return pieces }
        // A piece can only be late, never early, so the room's delay is what the pieces that are on time
        // show: the largest lags (short of an odd one out).
        let roomDelay = found[min(found.count - 1, Int(Double(found.count) * 0.85))]
        return zip(pieces, lags).map { piece, lag in
            guard let lag, abs(lag - roomDelay) <= SpeechAudio.samples(0.6) else { return piece }
            return (piece.samples, piece.start + lag - roomDelay)
        }
    }

    /// Stretches of exact silence at least `minimum` samples long.
    static func silentRuns(_ samples: [Float], minimum: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        samples.withUnsafeBufferPointer { values in
            var start: Int?
            for index in 0..<values.count {
                if abs(values[index]) < silence {
                    if start == nil { start = index }
                } else if let begin = start {
                    if index - begin >= minimum { runs.append(begin..<index) }
                    start = nil
                }
            }
            if let begin = start, values.count - begin >= minimum { runs.append(begin..<values.count) }
        }
        return runs
    }

    /// Repairs a meeting's call track on disk if it needs it: the repaired track replaces the recording,
    /// which is kept next to it. True if something was repaired.
    public static func repairFile(meetingId: String) throws -> Bool {
        guard let url = AppPaths.existingAudio(for: meetingId, channel: .system) else { return false }
        // Repaired before: never twice, and never over the kept original.
        for ext in ["m4a", "caf"] where FileManager.default.fileExists(atPath: AppPaths.originalSystemFile(for: meetingId, extension: ext).path) {
            return false
        }
        let samples = try SpeechAudio.load(url)
        guard let damage = damage(in: samples) else { return false }
        Log.audio.info("Repairing the call track of \(meetingId): \(damage.gaps) gaps, ratio \(damage.ratio)")
        let microphone = try AppPaths.existingAudio(for: meetingId, channel: .microphone).map(SpeechAudio.load)
        let repaired = repair(samples, ratio: damage.ratio, echo: microphone)
        let target = AppPaths.audioFile(for: meetingId, channel: .system)
        let temporary = target.deletingLastPathComponent().appendingPathComponent("system-repaired.m4a")
        let writer = try AudioFileWriter(url: temporary, encoding: .aac)
        var offset = 0
        let chunk = SpeechAudio.samples(30)
        while offset < repaired.count {
            let end = min(offset + chunk, repaired.count)
            try writer.write(Array(repaired[offset..<end]))
            offset = end
        }
        writer.close()
        let original = AppPaths.originalSystemFile(for: meetingId, extension: url.pathExtension)
        try? FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: url, to: original)
        if url != target { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: temporary, to: target)
        return true
    }
}

extension SpeechAudio {
    /// Samples taken at `from` Hz played back at `to` Hz: longer or shorter by their ratio, same pitch as
    /// they were recorded at.
    static func resample(_ samples: [Float], from: Double, to: Double) -> [Float] {
        guard !samples.isEmpty, from != to,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else { return samples }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * to / from + 4096)
        var result: [Float] = []
        var supplied = false
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in
                if supplied {
                    state.pointee = .endOfStream
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return source
            }
            if buffer.frameLength > 0 {
                result += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            if status != .haveData || error != nil { break }
        }
        return result
    }
}
