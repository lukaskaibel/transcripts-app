import Foundation
import Testing
@testable import TranscriptsKit

/// Something like speech at 16 kHz: syllables of a voiced sound (a pitch with harmonics and some breath)
/// with short pauses, while `talking` says so, over a faint noise floor.
private func speechLike(seconds: Double, seed: UInt64, pitch: ClosedRange<Float>, talking: (Double) -> Bool = { _ in true }) -> [Float] {
    var generator = SeededGenerator(seed: seed)
    let count = SpeechAudio.samples(seconds)
    var result = [Float](repeating: 0, count: count)
    var position = 0
    while position < count {
        let length = Int(Float.random(in: 0.12...0.3, using: &generator) * 16_000)
        let pause = Int(Float.random(in: 0.04...0.18, using: &generator) * 16_000)
        let f0 = Float.random(in: pitch, using: &generator)
        let loudness = Float.random(in: 0.15...0.35, using: &generator)
        if talking(SpeechAudio.seconds(position)) {
            for offset in 0..<length where position + offset < count {
                let t = Float(position + offset) / 16_000
                let envelope = sin(Float.pi * Float(offset) / Float(length))
                var value: Float = 0
                for harmonic in 1...10 { value += sin(2 * .pi * Float(harmonic) * f0 * t) / Float(harmonic) }
                value += Float.random(in: -0.3...0.3, using: &generator)
                result[position + offset] = loudness * envelope * value
            }
        }
        position += length + pause
    }
    for index in result.indices { result[index] += Float.random(in: -1e-3...1e-3, using: &generator) }
    return result
}

private func energy(_ samples: [Float], from: Double, to: Double) -> Float {
    let slice = samples[SpeechAudio.samples(from)..<SpeechAudio.samples(to)]
    return slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)
}

private func decibels(_ ratio: Float) -> Float { 10 * log10(ratio) }

@Suite struct EchoSuppressorTests {
    @Test func theFFTGoesThereAndBack() {
        let fft = RealFFT(count: 512)
        let signal = (0..<512).map { Float(sin(Double($0) * 0.37) + 0.2 * cos(Double($0) * 1.9)) }
        var real = [Float](repeating: 0, count: 256), imaginary = [Float](repeating: 0, count: 256)
        fft.forward(signal, at: 0, real: &real, imaginary: &imaginary)
        var back = [Float](repeating: 0, count: 512)
        fft.inverse(real: real, imaginary: imaginary, into: &back)
        #expect(zip(signal, back).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    /// The call talks, then the user, by turns; through the speakers the call comes back into the
    /// microphone 40 ms later with a bit of room.
    @Test func theCallsEchoGoesAndTheUsersVoiceStays() throws {
        let callTalks: (Double) -> Bool = { Int($0 / 10) % 2 == 0 }
        let call = speechLike(seconds: 60, seed: 1, pitch: 100...140, talking: callTalks)
        let user = speechLike(seconds: 60, seed: 2, pitch: 170...230, talking: { !callTalks($0) })
        let delay = SpeechAudio.samples(0.04)
        let room: [(Int, Float)] = [(0, 0.3), (SpeechAudio.samples(0.015), 0.15), (SpeechAudio.samples(0.04), 0.08), (SpeechAudio.samples(0.08), 0.04)]
        var microphone = user
        for index in microphone.indices {
            for (lag, gain) in room where index - delay - lag >= 0 {
                microphone[index] += gain * call[index - delay - lag]
            }
        }

        let cleaned = try #require(EchoSuppressor.clean(microphone: microphone, reference: call))
        #expect(cleaned.count == microphone.count)
        for start in [2.0, 22, 42] {
            let removed = decibels(energy(microphone, from: start, to: start + 7) / energy(cleaned, from: start, to: start + 7))
            #expect(removed > 15, "only \(removed) dB of echo removed at \(start) s")
        }
        for start in [12.0, 32, 52] {
            let lost = decibels(energy(microphone, from: start, to: start + 7) / energy(cleaned, from: start, to: start + 7))
            #expect(abs(lost) < 1.5, "the user's voice changed by \(lost) dB at \(start) s")
        }
    }

    @Test func withHeadphonesNothingChanges() {
        let call = speechLike(seconds: 40, seed: 3, pitch: 100...140)
        let user = speechLike(seconds: 40, seed: 4, pitch: 170...230)
        #expect(EchoSuppressor.clean(microphone: user, reference: call) == nil)
    }
}

@Suite struct CallTrackRepairTests {
    /// What the app recorded from 44.1 kHz speakers read as 48 kHz: the call squeezed by 44.1 / 48, and
    /// whenever it fell half a second behind the clock, the missing time padded with silence. With `late`,
    /// the recording now and then got round to a piece only a moment after it arrived and padded that much
    /// more (in the real recordings about a third of the pieces).
    func recordedTheOldWay(_ truth: [Float], late: Bool = false) -> [Float] {
        var generator = SeededGenerator(seed: 77)
        let ratio = 44_100.0 / 48_000.0
        let squeezed = SpeechAudio.resample(truth, from: SpeechAudio.sampleRate, to: SpeechAudio.sampleRate * ratio)
        var written: [Float] = []
        var offset = 0
        var elapsed = 0.0
        while offset < squeezed.count {
            elapsed += 0.01
            let chunk = Array(squeezed[offset..<min(offset + 147, squeezed.count)])
            offset += chunk.count
            let behind = SpeechAudio.samples(elapsed) - (written.count + chunk.count)
            if behind > SpeechAudio.samples(0.5) {
                let extra = late && Double.random(in: 0...1, using: &generator) < 0.4 ? SpeechAudio.samples(Double.random(in: 0.05...0.3, using: &generator)) : 0
                written += [Float](repeating: 0, count: behind + extra)
            }
            written += chunk
        }
        return Array(written.prefix(truth.count))
    }

    /// The share of seconds that sound like the original at the same time again (give or take 30 ms).
    func matchingSeconds(_ repaired: [Float], _ truth: [Float]) -> Double {
        var matching = 0
        var windows = 0
        for second in stride(from: 3, to: 55, by: 2) {
            windows += 1
            let start = SpeechAudio.samples(Double(second))
            let original = Array(truth[start..<(start + 16_000)])
            var best: Float = 0
            for lag in stride(from: -480, through: 480, by: 16) {
                let shifted = Array(repaired[(start + lag)..<(start + lag + 16_000)])
                let dot = zip(original, shifted).reduce(0) { $0 + $1.0 * $1.1 }
                let norm = sqrt(original.reduce(0) { $0 + $1 * $1 } * shifted.reduce(0) { $0 + $1 * $1 })
                best = max(best, dot / max(norm, 1e-9))
            }
            if best > 0.8 { matching += 1 }
        }
        return Double(matching) / Double(windows)
    }

    @Test func lateGapsAreSetRightByTheEcho() throws {
        let truth = speechLike(seconds: 60, seed: 7, pitch: 100...180)
        let recorded = recordedTheOldWay(truth, late: true)
        let damage = try #require(CallTrackRepair.damage(in: recorded))
        // Through the speakers the microphone hears the call 30 ms later, along with the user.
        let user = speechLike(seconds: 60, seed: 8, pitch: 170...230, talking: { Int($0 / 7) % 3 == 0 })
        let delay = SpeechAudio.samples(0.03)
        let microphone = user.indices.map { user[$0] + ($0 >= delay ? 0.3 * truth[$0 - delay] : 0) }

        let withoutEcho = matchingSeconds(CallTrackRepair.repair(recorded, ratio: damage.ratio), truth)
        let withEcho = matchingSeconds(CallTrackRepair.repair(recorded, ratio: damage.ratio, echo: microphone), truth)
        #expect(withEcho >= 0.85, "\(withEcho) of the seconds match with the echo")
        #expect(withEcho > withoutEcho)
    }

    @Test func theOldDamageIsFoundAndRepaired() throws {
        let truth = speechLike(seconds: 60, seed: 5, pitch: 100...180)
        let recorded = recordedTheOldWay(truth)
        let damage = try #require(CallTrackRepair.damage(in: recorded))
        #expect(abs(damage.ratio - 44_100.0 / 48_000.0) < 1e-6)
        #expect(damage.gaps >= 8)

        let repaired = CallTrackRepair.repair(recorded, ratio: damage.ratio)
        #expect(repaired.count == recorded.count)
        // Every second sounds like the original at the same time again.
        let share = matchingSeconds(repaired, truth)
        #expect(share >= 0.85, "\(share) of the seconds match")
    }

    /// A call app that sends exact silence between turns, of any length, at no particular pace.
    @Test func digitalSilenceBetweenTurnsIsNoDamage() {
        var generator = SeededGenerator(seed: 9)
        for trial in 0..<5 {
            var track: [Float] = []
            let talk = speechLike(seconds: 30, seed: UInt64(20 + trial), pitch: 100...180)
            var offset = 0
            while track.count < SpeechAudio.samples(600) {
                let length = SpeechAudio.samples(Double.random(in: 2...9, using: &generator))
                track += talk[(offset % (talk.count - length))..<(offset % (talk.count - length) + length)]
                offset += length
                track += [Float](repeating: 0, count: SpeechAudio.samples(Double.random(in: 0.3...1.2, using: &generator)))
            }
            #expect(CallTrackRepair.damage(in: track) == nil, "trial \(trial)")
        }
    }

    @Test func aHealthyTrackIsLeftAlone() {
        let truth = speechLike(seconds: 60, seed: 6, pitch: 100...180)
        #expect(CallTrackRepair.damage(in: truth) == nil)
        // Long silence between calls is not damage either.
        let withSilence = truth + [Float](repeating: 0, count: SpeechAudio.samples(20)) + truth
        #expect(CallTrackRepair.damage(in: withSilence) == nil)
    }
}

@Suite struct MicrophoneWordsTests {
    /// Levels per 20 ms frame for 30 s: the user speaks from 2 to 6 s and from 20 to 24 s, alone; the call
    /// from 10 to 16 s, which the microphone heard as an echo and the cleaning turned down by 35 dB. A soft
    /// word of the user sits in the middle of their sentence at 4 s.
    func levels() -> (raw: [Float], cleaned: [Float], call: [Float]) {
        let frames = 1500
        var raw = [Float](repeating: -70, count: frames), cleaned = raw, call = raw
        for frame in 0..<frames {
            let t = Double(frame) * 0.02
            if (2..<6).contains(t) || (20..<24).contains(t) { raw[frame] = -22; cleaned[frame] = -22.5 }
            if (3.9..<4.2).contains(t) { raw[frame] = -40; cleaned[frame] = -41 }
            if (10..<16).contains(t) { call[frame] = -12; raw[frame] = -21; cleaned[frame] = -56 }
        }
        return (raw, cleaned, call)
    }

    @Test func theUsersWordsStayAndTheEchoGoes() {
        let (raw, cleaned, call) = levels()
        var words: [TimedWord] = []
        for start in stride(from: 2.0, to: 6, by: 0.3) { words.append(TimedWord(text: "ich", start: start, end: start + 0.25)) }
        for start in stride(from: 10.0, to: 16, by: 0.3) { words.append(TimedWord(text: "echo", start: start, end: start + 0.25)) }
        for start in stride(from: 20.0, to: 24, by: 0.3) { words.append(TimedWord(text: "ich", start: start, end: start + 0.25)) }
        let own = MicrophoneWords.own(words.sorted { $0.start < $1.start }, cleaned: cleaned, raw: raw, call: call)
        #expect(!own.contains { $0.text == "echo" })
        #expect(own.filter { $0.text == "ich" }.count == words.filter { $0.text == "ich" }.count)
    }
}
