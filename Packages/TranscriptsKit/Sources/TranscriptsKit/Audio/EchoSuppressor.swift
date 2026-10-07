import Accelerate
import Foundation

/// Takes the call's echo out of the microphone track after a meeting.
///
/// Through speakers, the call comes back into the microphone a moment later and quieter: every remote
/// voice ends up in the recording twice, and in the user's own lines. The call track is the clean original,
/// so the echo can be predicted from it: how much of each frequency band of the call reaches the
/// microphone, with which delay, and how long the room lets it ring. Wherever that prediction explains what
/// the microphone heard, the microphone is turned down; where the user speaks over it, it stays.
///
/// With headphones there is no echo, and the microphone is left as it is.
public enum EchoSuppressor {
    static let frameLength = 512
    static let hop = 256
    /// The echo's tail in frames (24 × 16 ms): how long the room keeps a sound going.
    static let taps = 24
    /// Predicted echo is weighed this many times over before it is taken out: the prediction is rough, and a
    /// little echo left over is worse than a little of the user's voice taken away while the call talks.
    static let overestimation: Float = 8
    /// The quietest a frequency is turned down to (-40 dB).
    static let floor: Float = 0.01

    /// The microphone without the call's echo, or nil when there is none worth taking out.
    public static func clean(microphone: [Float], reference: [Float]) -> [Float]? {
        let length = min(microphone.count, reference.count)
        guard length >= SpeechAudio.samples(10) else { return nil }
        guard let delays = Self.delays(microphone: microphone, reference: reference, length: length) else { return nil }
        let frames = 1 + (length - frameLength) / hop
        let shifts = (0..<frames).map { delays.frameShift(at: $0) }
        let spectra = Spectra(microphone: microphone, reference: reference, frames: frames)
        guard let model = EchoModel.fit(spectra, shifts: shifts), model.echoShare >= 0.02 else { return nil }
        return apply(model, microphone: microphone, reference: reference, frames: frames, shifts: shifts)
    }

    // MARK: Delay

    /// How much later the call arrives in the microphone, over the meeting. It moves a little (the two
    /// recordings' clocks drift, and repaired old recordings jump), so it is measured every few seconds.
    struct Delays {
        /// Delay in samples per block of `block` samples; positive: the microphone is later.
        var values: [Double]
        var block: Int

        func frameShift(at frame: Int) -> Int {
            let center = Double(frame * EchoSuppressor.hop + EchoSuppressor.frameLength / 2)
            let position = center / Double(block) - 0.5
            let lower = max(0, min(values.count - 1, Int(position.rounded(.down))))
            let upper = min(values.count - 1, lower + 1)
            let fraction = max(0, min(1, position - Double(lower)))
            let delay = values[lower] * (1 - fraction) + values[upper] * fraction
            return Int((delay / Double(EchoSuppressor.hop)).rounded())
        }
    }

    /// The delay, measured by cross-correlation with phase transform (a sharp peak where the microphone
    /// repeats the call) on windows of the call where someone speaks, at a quarter of the sample rate.
    static func delays(microphone: [Float], reference: [Float], length: Int) -> Delays? {
        let decimation = 4
        let block = SpeechAudio.samples(3)
        let window = SpeechAudio.samples(6) / decimation
        let maxLag = SpeechAudio.samples(1) / decimation
        let size = 1 << 16
        let fft = RealFFT(count: size)
        let mic = decimated(microphone, by: decimation, count: length)
        let ref = decimated(reference, by: decimation, count: length)
        let shortLength = length / decimation
        var measured: [Double?] = []
        var a = [Float](repeating: 0, count: size)
        var b = [Float](repeating: 0, count: size)
        var blockStart = 0
        while blockStart < length {
            defer { blockStart += block }
            let start = max(maxLag, min((blockStart + block / 2) / decimation - window / 2, shortLength - window - maxLag))
            guard start >= maxLag, start + window + maxLag <= shortLength,
                  SpeechAudio.rms(ref[start..<(start + window)]) >= 0.005 else {
                measured.append(nil)
                continue
            }
            vDSP.fill(&a, with: 0)
            vDSP.fill(&b, with: 0)
            a.replaceSubrange(0..<(window + 2 * maxLag), with: mic[(start - maxLag)..<(start + window + maxLag)])
            b.replaceSubrange(0..<window, with: ref[start..<(start + window)])
            let correlation = fft.phaseCorrelation(a, b)
            let lags = Array(correlation[0..<(2 * maxLag)])
            let (peakIndex, peak) = vDSP.indexOfMaximum(lags)
            let mean = vDSP.meanMagnitude(lags)
            measured.append(peak / max(mean, 1e-12) > 12 ? Double((Int(peakIndex) - maxLag) * decimation) : nil)
        }
        let found = measured.compactMap { $0 }
        let active = measured.count
        guard found.count >= 3, Double(found.count) >= Double(active) * 0.1 else { return nil }
        // Fill the gaps from the neighbours, then smooth out single wrong peaks.
        var filled = measured
        var lastKnown: Double?
        for index in filled.indices {
            if let value = filled[index] { lastKnown = value } else { filled[index] = lastKnown }
        }
        var nextKnown: Double?
        for index in filled.indices.reversed() {
            if let value = measured[index] { nextKnown = value }
            if filled[index] == nil { filled[index] = nextKnown }
        }
        let values = filled.map { $0 ?? found[found.count / 2] }
        let smoothed = values.indices.map { index -> Double in
            let neighbourhood = values[max(0, index - 2)...min(values.count - 1, index + 2)].sorted()
            return neighbourhood[neighbourhood.count / 2]
        }
        return Delays(values: smoothed, block: block)
    }

    /// Every `factor`-th sample, averaged over its neighbours (a rough low-pass, enough for finding a delay).
    static func decimated(_ samples: [Float], by factor: Int, count: Int) -> [Float] {
        let output = count / factor
        guard output > 0 else { return [] }
        var result = [Float](repeating: 0, count: output)
        let filter = [Float](repeating: 1 / Float(factor), count: factor)
        samples.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), filter, &result, vDSP_Length(output), vDSP_Length(factor))
        }
        return result
    }

    // MARK: Spectra

    /// The window and the frequency bands the suppression works in.
    enum Bands {
        static let bins = frameLength / 2 + 1
        /// First bin of each band, plus the end: narrow bands at the bottom, wide at the top, like hearing.
        static let edges: [Int] = {
            var edges = Set<Int>()
            for step in 0...24 { edges.insert(Int((2 * pow(Double(bins) / 2, Double(step) / 24)).rounded())) }
            return [0] + edges.filter { $0 > 0 && $0 < bins }.sorted() + [bins]
        }()
        static let count = edges.count - 1
        static let ofBin: [Int] = {
            var result = [Int](repeating: 0, count: bins)
            for band in 0..<count {
                for bin in edges[band]..<edges[band + 1] { result[bin] = band }
            }
            return result
        }()

        /// Square root of a periodic Hann window: analysis and synthesis together add up to one.
        static let window: [Float] = (0..<frameLength).map { index in
            Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(frameLength))))
        }
    }

    /// Power per band and frame of both tracks, for fitting the echo.
    struct Spectra {
        var microphone: [Float]
        var reference: [Float]
        var frames: Int

        init(microphone mic: [Float], reference ref: [Float], frames: Int) {
            self.frames = frames
            let bands = Bands.count
            var micBands = [Float](repeating: 0, count: frames * bands)
            var refBands = [Float](repeating: 0, count: frames * bands)
            let fft = RealFFT(count: frameLength)
            var power = [Float](repeating: 0, count: Bands.bins)
            for frame in 0..<frames {
                fft.power(of: mic, at: frame * hop, window: Bands.window, into: &power)
                Self.sumBands(power, into: &micBands, at: frame * bands)
                fft.power(of: ref, at: frame * hop, window: Bands.window, into: &power)
                Self.sumBands(power, into: &refBands, at: frame * bands)
            }
            microphone = micBands
            reference = refBands
        }

        static func sumBands(_ power: [Float], into target: inout [Float], at offset: Int) {
            power.withUnsafeBufferPointer { bins in
                for band in 0..<Bands.count {
                    var sum: Float = 0
                    let start = Bands.edges[band]
                    vDSP_sve(bins.baseAddress! + start, 1, &sum, vDSP_Length(Bands.edges[band + 1] - start))
                    target[offset + band] = sum
                }
            }
        }
    }

    // MARK: Echo model

    /// How much of the call's power reaches the microphone, per band and per frame after the direct sound.
    struct EchoModel {
        /// taps × bands
        var coefficients: [Float]
        /// The echo's share of the microphone's power while the call talks.
        var echoShare: Float

        static let maximumFrames = 20_000

        static func fit(_ spectra: Spectra, shifts: [Int]) -> EchoModel? {
            let bands = Bands.count
            let frames = spectra.frames
            // The call aligned to the microphone, with a frame of slack either way.
            var aligned = [Float](repeating: 0, count: frames * bands)
            for frame in 0..<frames {
                let source = frame - shifts[frame]
                guard source >= 1, source < frames - 1 else { continue }
                for band in 0..<bands {
                    aligned[frame * bands + band] = max(
                        spectra.reference[(source - 1) * bands + band],
                        spectra.reference[source * bands + band],
                        spectra.reference[(source + 1) * bands + band]
                    )
                }
            }
            // Frames in which the call clearly talks.
            var loudness = [Float](repeating: 0, count: frames)
            aligned.withUnsafeBufferPointer { values in
                for frame in 0..<frames {
                    vDSP_sve(values.baseAddress! + frame * bands, 1, &loudness[frame], vDSP_Length(bands))
                }
            }
            let threshold = loudness.sorted()[min(frames - 1, Int(Double(frames) * 0.4))]
            var active = (taps..<frames).filter { loudness[$0] > threshold && loudness[$0] > 0 }
            guard active.count >= 200 else { return nil }
            if active.count > maximumFrames {
                let step = Double(active.count) / Double(maximumFrames)
                active = (0..<maximumFrames).map { active[Int(Double($0) * step)] }
            }
            let n = active.count

            var coefficients = [Float](repeating: 0, count: taps * bands)
            var echo: Float = 0
            var total: Float = 0
            var design = [Float](repeating: 0, count: n * taps)
            var target = [Float](repeating: 0, count: n)
            for band in 0..<bands {
                // Scaled so the sums stay in a comfortable range for single precision.
                var scale: Float = 0
                for frame in active { scale += aligned[frame * bands + band] }
                scale = max(scale / Float(n), 1e-20)
                for (row, frame) in active.enumerated() {
                    for tap in 0..<taps { design[row * taps + tap] = aligned[(frame - tap) * bands + band] / scale }
                    target[row] = spectra.microphone[frame * bands + band] / scale
                }
                var weights = [Float](repeating: 1, count: n)
                var solution = [Float](repeating: 0, count: taps)
                for _ in 0..<4 {
                    guard let solved = weightedLeastSquares(design, target, weights: weights, rows: n, columns: taps) else { break }
                    solution = solved.map { max($0, 0) }
                    // Frames where the microphone is far louder than the echo would be are the user talking;
                    // they must not teach the model that the echo is loud.
                    let predicted = multiply(design, solution, rows: n, columns: taps)
                    for row in 0..<n { weights[row] = target[row] - predicted[row] > 2 * predicted[row] ? 0.05 : 1 }
                }
                for tap in 0..<taps { coefficients[tap * bands + band] = solution[tap] }
                let predicted = multiply(design, solution, rows: n, columns: taps)
                echo += zip(predicted, target).reduce(0) { $0 + min($1.0, $1.1) } * scale
                total += vDSP.sum(target) * scale
            }
            return EchoModel(coefficients: coefficients, echoShare: total > 0 ? echo / total : 0)
        }

        /// Least squares with a weight per row: (Aᵀ W A) x = Aᵀ W y, solved by Cholesky.
        static func weightedLeastSquares(_ design: [Float], _ target: [Float], weights: [Float], rows: Int, columns: Int) -> [Float]? {
            var weighted = design
            for row in 0..<rows {
                let weight = sqrt(weights[row])
                guard weight != 1 else { continue }
                for column in 0..<columns { weighted[row * columns + column] *= weight }
            }
            let weightedTarget = vDSP.multiply(target, vForce.sqrt(weights))
            var transposed = [Float](repeating: 0, count: rows * columns)
            vDSP_mtrans(weighted, 1, &transposed, 1, vDSP_Length(columns), vDSP_Length(rows))
            var normal = [Float](repeating: 0, count: columns * columns)
            vDSP_mmul(transposed, 1, weighted, 1, &normal, 1, vDSP_Length(columns), vDSP_Length(columns), vDSP_Length(rows))
            var right = [Float](repeating: 0, count: columns)
            vDSP_mmul(transposed, 1, weightedTarget, 1, &right, 1, vDSP_Length(columns), 1, vDSP_Length(rows))
            return solve(normal.map(Double.init), right.map(Double.init), size: columns)?.map(Float.init)
        }

        static func multiply(_ matrix: [Float], _ vector: [Float], rows: Int, columns: Int) -> [Float] {
            var result = [Float](repeating: 0, count: rows)
            vDSP_mmul(matrix, 1, vector, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(columns))
            return result
        }

        /// Solves a small symmetric positive system with a touch of regularisation (Cholesky).
        static func solve(_ matrix: [Double], _ vector: [Double], size: Int) -> [Double]? {
            var a = matrix
            let trace = (0..<size).reduce(0.0) { $0 + a[$1 * size + $1] }
            guard trace > 0 else { return nil }
            for i in 0..<size { a[i * size + i] += trace / Double(size) * 1e-4 }
            var lower = [Double](repeating: 0, count: size * size)
            for i in 0..<size {
                for j in 0...i {
                    var sum = a[i * size + j]
                    for k in 0..<j { sum -= lower[i * size + k] * lower[j * size + k] }
                    if i == j {
                        guard sum > 0 else { return nil }
                        lower[i * size + i] = sqrt(sum)
                    } else {
                        lower[i * size + j] = sum / lower[j * size + j]
                    }
                }
            }
            var y = [Double](repeating: 0, count: size)
            for i in 0..<size {
                var sum = vector[i]
                for k in 0..<i { sum -= lower[i * size + k] * y[k] }
                y[i] = sum / lower[i * size + i]
            }
            var x = [Double](repeating: 0, count: size)
            for i in stride(from: size - 1, through: 0, by: -1) {
                var sum = y[i]
                for k in (i + 1)..<size { sum -= lower[k * size + i] * x[k] }
                x[i] = sum / lower[i * size + i]
            }
            return x
        }
    }

    // MARK: Suppression

    static func apply(_ model: EchoModel, microphone: [Float], reference: [Float], frames: Int, shifts: [Int]) -> [Float] {
        let bins = Bands.bins
        let bands = Bands.count
        let half = frameLength / 2
        let fft = RealFFT(count: frameLength)
        let window = Bands.window
        let length = microphone.count
        // Coefficients per tap and bin.
        var perBin = [Float](repeating: 0, count: taps * bins)
        for tap in 0..<taps {
            for bin in 0..<bins { perBin[tap * bins + bin] = model.coefficients[tap * bands + Bands.ofBin[bin]] }
        }

        // The call's power per frame, computed when first needed and kept for a while in a ring.
        let ringSize = 1024
        var ring = [Float](repeating: 0, count: ringSize * bins)
        var ringFrame = [Int](repeating: -1, count: ringSize)
        var scratch = [Float](repeating: 0, count: bins)
        func referencePower(_ frame: Int) -> Int? {
            guard frame >= 0, frame < frames else { return nil }
            let slot = frame % ringSize
            if ringFrame[slot] != frame {
                fft.power(of: reference, at: frame * hop, window: window, into: &scratch)
                ring.replaceSubrange(slot * bins..<(slot + 1) * bins, with: scratch)
                ringFrame[slot] = frame
            }
            return slot * bins
        }

        // The aligned call of the last `taps` frames, newest at `frame % taps`.
        var history = [Float](repeating: 0, count: taps * bins)
        var output = [Float](repeating: 0, count: length)
        var previousGain = [Float](repeating: 1, count: bins)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var micPower = [Float](repeating: 0, count: bins)
        var echo = [Float](repeating: 0, count: bins)
        var gain = [Float](repeating: 0, count: bins)
        var smoothed = [Float](repeating: 0, count: bins)
        var frameOut = [Float](repeating: 0, count: frameLength)
        var one: Float = 1
        var minusOverestimation = -overestimation
        var lowest = floor
        var keep: Float = 0.6
        var take: Float = 0.4

        for frame in 0..<frames {
            let slot = frame % taps
            let source = frame - shifts[frame]
            if let a = referencePower(source - 1), let b = referencePower(source), let c = referencePower(source + 1) {
                ring.withUnsafeBufferPointer { values in
                    history.withUnsafeMutableBufferPointer { target in
                        let destination = target.baseAddress! + slot * bins
                        vDSP_vmax(values.baseAddress! + a, 1, values.baseAddress! + b, 1, destination, 1, vDSP_Length(bins))
                        vDSP_vmax(destination, 1, values.baseAddress! + c, 1, destination, 1, vDSP_Length(bins))
                    }
                }
            } else {
                history.replaceSubrange(slot * bins..<(slot + 1) * bins, with: repeatElement(0, count: bins))
            }

            // Predicted echo: the call of the last frames through the room.
            vDSP.fill(&echo, with: 0)
            perBin.withUnsafeBufferPointer { coefficients in
                history.withUnsafeBufferPointer { past in
                    echo.withUnsafeMutableBufferPointer { sum in
                        for age in 0..<min(taps, frame + 1) {
                            let row = coefficients.baseAddress! + age * bins
                            let pastFrame = past.baseAddress! + ((frame - age) % taps) * bins
                            vDSP_vma(row, 1, pastFrame, 1, sum.baseAddress!, 1, sum.baseAddress!, 1, vDSP_Length(bins))
                        }
                    }
                }
            }

            fft.forward(microphone, at: frame * hop, window: window, real: &real, imaginary: &imaginary)
            RealFFT.power(real: real, imaginary: imaginary, into: &micPower)
            // gain = max(floor, 1 - overestimation · echo / microphone), then down at once and back up
            // gently: min(gain, 0.6 · previous + 0.4 · gain).
            vDSP.add(1e-12, micPower, result: &micPower)
            vDSP.divide(echo, micPower, result: &gain)
            gain.withUnsafeMutableBufferPointer { g in
                smoothed.withUnsafeMutableBufferPointer { s in
                    let n = vDSP_Length(bins)
                    vDSP_vsmsa(g.baseAddress!, 1, &minusOverestimation, &one, g.baseAddress!, 1, n)
                    vDSP_vthr(g.baseAddress!, 1, &lowest, g.baseAddress!, 1, n)
                    vDSP_vsmul(previousGain, 1, &keep, s.baseAddress!, 1, n)
                    vDSP_vsma(g.baseAddress!, 1, &take, s.baseAddress!, 1, s.baseAddress!, 1, n)
                    vDSP_vmin(g.baseAddress!, 1, s.baseAddress!, 1, g.baseAddress!, 1, n)
                }
            }
            previousGain = gain
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    gain.withUnsafeBufferPointer { g in
                        re[0] *= g[0]
                        im[0] *= g[bins - 1]
                        vDSP_vmul(re.baseAddress! + 1, 1, g.baseAddress! + 1, 1, re.baseAddress! + 1, 1, vDSP_Length(half - 1))
                        vDSP_vmul(im.baseAddress! + 1, 1, g.baseAddress! + 1, 1, im.baseAddress! + 1, 1, vDSP_Length(half - 1))
                    }
                }
            }
            fft.inverse(real: real, imaginary: imaginary, into: &frameOut)
            let start = frame * hop
            let count = min(frameLength, length - start)
            guard count > 0 else { continue }
            frameOut.withUnsafeBufferPointer { values in
                output.withUnsafeMutableBufferPointer { target in
                    let destination = target.baseAddress! + start
                    vDSP_vma(values.baseAddress!, 1, window, 1, destination, 1, destination, 1, vDSP_Length(count))
                }
            }
        }
        // The first and the last half frame got only one window, the rest after them none: keep them as they were.
        for index in 0..<min(hop, length) { output[index] = microphone[index] }
        let covered = frames * hop
        if covered < length {
            output.replaceSubrange(covered..<length, with: microphone[covered..<length])
        }
        return output
    }
}

/// A real-input FFT of a fixed size, on top of vDSP's DFT. Spectra are packed the way vDSP does it:
/// `real[0]` is the DC part, `imaginary[0]` the Nyquist part, and they come out scaled by 2.
final class RealFFT {
    let count: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private var frame: [Float]
    private var evenIn: [Float]
    private var oddIn: [Float]
    private var real: [Float]
    private var imaginary: [Float]

    init(count: Int) {
        self.count = count
        forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(count), .FORWARD)!
        inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(count), .INVERSE)!
        frame = [Float](repeating: 0, count: count)
        evenIn = [Float](repeating: 0, count: count / 2)
        oddIn = [Float](repeating: 0, count: count / 2)
        real = [Float](repeating: 0, count: count / 2)
        imaginary = [Float](repeating: 0, count: count / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    /// Spectrum of `count` samples from `start` (zero beyond the end), optionally windowed.
    func forward(_ signal: [Float], at start: Int, window: [Float]? = nil, real: inout [Float], imaginary: inout [Float]) {
        let available = max(0, min(count, signal.count - start))
        if available < count { vDSP.fill(&frame, with: 0) }
        if available > 0 { frame.replaceSubrange(0..<available, with: signal[start..<(start + available)]) }
        if let window { vDSP.multiply(frame, window, result: &frame) }
        frame.withUnsafeBufferPointer { samples in
            samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) { pairs in
                evenIn.withUnsafeMutableBufferPointer { even in
                    oddIn.withUnsafeMutableBufferPointer { odd in
                        var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
                        vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(count / 2))
                    }
                }
            }
        }
        vDSP_DFT_Execute(forwardSetup, evenIn, oddIn, &real, &imaginary)
    }

    /// Back to `count` samples, undoing the scaling of `forward`.
    func inverse(real: [Float], imaginary: [Float], into output: inout [Float]) {
        vDSP_DFT_Execute(inverseSetup, real, imaginary, &evenIn, &oddIn)
        evenIn.withUnsafeMutableBufferPointer { even in
            oddIn.withUnsafeMutableBufferPointer { odd in
                var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
                output.withUnsafeMutableBufferPointer { target in
                    target.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: count / 2) { pairs in
                        vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(count / 2))
                    }
                }
            }
        }
        vDSP.multiply(1 / Float(2 * count), output, result: &output)
    }

    /// Power per bin (count / 2 + 1 of them) of a packed spectrum, undoing the scaling.
    static func power(real: [Float], imaginary: [Float], into power: inout [Float]) {
        let half = real.count
        power[0] = real[0] * real[0] / 4
        power[half] = imaginary[0] * imaginary[0] / 4
        real.withUnsafeBufferPointer { re in
            imaginary.withUnsafeBufferPointer { im in
                power.withUnsafeMutableBufferPointer { target in
                    var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re.baseAddress! + 1), imagp: UnsafeMutablePointer(mutating: im.baseAddress! + 1))
                    vDSP_zvmags(&split, 1, target.baseAddress! + 1, 1, vDSP_Length(half - 1))
                    var quarter: Float = 0.25
                    vDSP_vsmul(target.baseAddress! + 1, 1, &quarter, target.baseAddress! + 1, 1, vDSP_Length(half - 1))
                }
            }
        }
    }

    func power(of signal: [Float], at start: Int, window: [Float], into power: inout [Float]) {
        forward(signal, at: start, window: window, real: &real, imaginary: &imaginary)
        Self.power(real: real, imaginary: imaginary, into: &power)
    }

    /// Cross-correlation of `a` and `b` (both `count` long, zero-padded) with only the phase kept: a sharp
    /// peak at the lag where `a` repeats `b`. Index k means `a` is k samples later.
    func phaseCorrelation(_ a: [Float], _ b: [Float]) -> [Float] {
        let half = count / 2
        var ar = [Float](repeating: 0, count: half), ai = [Float](repeating: 0, count: half)
        var br = [Float](repeating: 0, count: half), bi = [Float](repeating: 0, count: half)
        forward(a, at: 0, real: &ar, imaginary: &ai)
        forward(b, at: 0, real: &br, imaginary: &bi)
        // DC and Nyquist are real; keep their sign only.
        let dc: Float = ar[0] * br[0] >= 0 ? 1 : -1
        let nyquist: Float = ai[0] * bi[0] >= 0 ? 1 : -1
        var cr = [Float](repeating: 0, count: half), ci = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        ar.withUnsafeMutableBufferPointer { arp in
            ai.withUnsafeMutableBufferPointer { aip in
                br.withUnsafeMutableBufferPointer { brp in
                    bi.withUnsafeMutableBufferPointer { bip in
                        cr.withUnsafeMutableBufferPointer { crp in
                            ci.withUnsafeMutableBufferPointer { cip in
                                var first = DSPSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!)
                                var second = DSPSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
                                var product = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
                                // conj(b) · a
                                vDSP_zvmul(&second, 1, &first, 1, &product, 1, vDSP_Length(half), -1)
                                vDSP_zvabs(&product, 1, &magnitude, 1, vDSP_Length(half))
                            }
                        }
                    }
                }
            }
        }
        vDSP.add(1e-20, magnitude, result: &magnitude)
        vDSP.divide(cr, magnitude, result: &cr)
        vDSP.divide(ci, magnitude, result: &ci)
        cr[0] = dc
        ci[0] = nyquist
        var result = [Float](repeating: 0, count: count)
        inverse(real: cr, imaginary: ci, into: &result)
        return result
    }
}
