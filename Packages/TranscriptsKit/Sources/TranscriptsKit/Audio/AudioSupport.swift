import Accelerate
import AVFoundation
import Foundation

/// The one format every model here wants: 16 kHz mono Float32.
public enum SpeechAudio {
    public static let sampleRate: Double = 16_000
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    public static func seconds(_ samples: Int) -> Double { Double(samples) / sampleRate }
    public static func samples(_ seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }

    /// Root mean square of the samples.
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return value
    }

    public static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    /// Loudness for a meter: 0 at -55 dBFS or quieter, 1 at -10 dBFS or louder.
    public static func meterLevel(_ samples: [Float]) -> Float {
        let rms = rms(samples)
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db + 55) / 45, 0), 1)
    }

    /// Wraps samples in a buffer of `format`.
    public static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Reads any audio file as 16 kHz mono samples.
    public static func load(_ url: URL) throws -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(samples(duration(of: url)) + 1024)
        try read(url) { result += $0 }
        return result
    }

    /// Reads any audio file as 16 kHz mono samples, a piece at a time, for files too long to hold at once.
    public static func read(_ url: URL, _ body: ([Float]) throws -> Void) throws {
        let reader = try AudioFileReader(url: url)
        while let samples = try reader.next() { try body(samples) }
    }

    /// Duration of an audio file in seconds, without decoding it.
    public static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Converts buffers of any format to 16 kHz mono, keeping filter state between calls so a live
/// stream converts without clicks at buffer boundaries.
public final class StreamingResampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let passthrough: Bool

    public init(from inputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: SpeechAudio.format) else {
            throw AudioError.unsupportedFormat(inputFormat.description)
        }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        passthrough = inputFormat.sampleRate == SpeechAudio.sampleRate
            && inputFormat.channelCount == 1
            && inputFormat.commonFormat == .pcmFormatFloat32
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if passthrough, let data = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        let ratio = SpeechAudio.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: SpeechAudio.format, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// Drains the converter at the end of a stream.
    public func flush() -> [Float] {
        guard !passthrough, let output = AVAudioPCMBuffer(pcmFormat: SpeechAudio.format, frameCapacity: 4096) else { return [] }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// Reads an audio file as 16 kHz mono samples, a piece at a time. A damaged stretch (the seconds a video from a meeting
/// app lost of its sound, which Core Audio won't decode while other players skip them) comes out as silence of its
/// length, so what follows stays at its time. A file with more damage than `damageLimit` isn't read.
public final class AudioFileReader {
    /// How much of a file may be damaged and it still counts as readable, in seconds: a tenth, at least ten seconds.
    static func damageLimit(of length: TimeInterval) -> TimeInterval { max(10, length / 10) }

    private static let chunk: AVAudioFrameCount = 65_536
    /// About one compressed packet (1024 frames in AAC): a piece with damage is read again this much at a time, so no
    /// more than the damage is lost.
    private static let step: AVAudioFrameCount = 1024

    private let file: AVAudioFile
    private let resampler: StreamingResampler
    private let buffer: AVAudioPCMBuffer
    /// Up to here the file is read a step at a time.
    private var carefulUntil: AVAudioFramePosition = 0
    private var finished = false
    /// Seconds read as silence because they couldn't be decoded.
    private(set) var damaged: TimeInterval = 0

    public init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        resampler = try StreamingResampler(from: file.processingFormat)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.chunk) else {
            throw AudioError.unsupportedFormat(file.processingFormat.description)
        }
        self.buffer = buffer
    }

    /// The next piece; nil after the last.
    public func next() throws -> [Float]? {
        guard !finished else { return nil }
        while file.framePosition < file.length {
            let position = file.framePosition
            let count = position < carefulUntil ? Self.step : Self.chunk
            do {
                try file.read(into: buffer, frameCount: count)
                if buffer.frameLength == 0 { break }
            } catch where count > Self.step {
                file.framePosition = position
                carefulUntil = position + AVAudioFramePosition(count)
                continue
            } catch {
                try skipDamage(at: position, error: error)
            }
            return resampler.convert(buffer)
        }
        finished = true
        if damaged > 0 {
            Log.audio.info("\(self.file.url.lastPathComponent) had \(self.damaged, format: .fixed(precision: 1)) s of audio that couldn't be decoded; read as silence")
        }
        return resampler.flush()
    }

    /// The step at `position` can't be decoded: silence instead, and on after it.
    private func skipDamage(at position: AVAudioFramePosition, error: Error) throws {
        let rate = file.processingFormat.sampleRate
        let frames = min(AVAudioFramePosition(Self.step), file.length - position)
        damaged += Double(frames) / rate
        guard damaged <= Self.damageLimit(of: Double(file.length) / rate) else { throw error }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(file.processingFormat.channelCount) {
            buffer.floatChannelData?[channel].update(repeating: 0, count: Int(frames))
        }
        file.framePosition = position + frames
    }
}

/// Appends 16 kHz mono samples to an audio file.
public final class AudioFileWriter {
    public enum Encoding {
        /// 16-bit PCM in a CAF file. Used while recording: a crash leaves a readable file behind.
        case pcm
        /// AAC in an M4A file, about a fifth of the size. Used for keeping recordings.
        case aac
    }

    public let url: URL
    private var file: AVAudioFile?
    public private(set) var samplesWritten = 0

    public init(url: URL, encoding: Encoding = .pcm) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any]
        switch encoding {
        case .pcm:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: SpeechAudio.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        case .aac:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: SpeechAudio.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ]
        }
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func write(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty, let buffer = SpeechAudio.buffer(from: samples) else { return }
        try file.write(from: buffer)
        samplesWritten += samples.count
    }

    /// Finishes the file. Further writes are ignored.
    public func close() {
        file?.close()
        file = nil
    }

    public var duration: Double { SpeechAudio.seconds(samplesWritten) }
}

public enum AudioError: LocalizedError {
    case unsupportedFormat(String)
    /// The message says what failed, as one sentence in the interface's language.
    case coreAudio(String, OSStatus)
    /// The message says what the app may not use, as one sentence in the interface's language.
    case permissionDenied(String)
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): String(localized: "Dieses Audioformat wird nicht unterstützt (\(format)).")
        case .coreAudio(let message, _): message
        case .permissionDenied(let message): message
        case .noInputDevice: String(localized: "Es ist kein Mikrofon verfügbar.")
        }
    }
}

/// Something that delivers 16 kHz mono samples while running: the microphone, the system audio tap,
/// or a file played back for tests.
public protocol AudioSource: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Plays a file into a recording as if it were live, `speed` times faster than real time.
public final class FileAudioSource: AudioSource, @unchecked Sendable {
    public var onSamples: (([Float]) -> Void)?
    private let samples: [Float]
    private let speed: Double
    private var task: Task<Void, Never>?
    /// Called once the whole file was delivered.
    public var onFinished: (() -> Void)?

    public init(url: URL, speed: Double = 1) throws {
        samples = try SpeechAudio.load(url)
        self.speed = speed
    }

    public var duration: Double { SpeechAudio.seconds(samples.count) }

    private init() {
        samples = []
        speed = 1
    }

    /// A source that never delivers anything.
    static var silent: FileAudioSource { FileAudioSource() }

    public func start() throws {
        let chunk = SpeechAudio.samples(0.1)
        task = Task.detached { [weak self, samples, speed] in
            var offset = 0
            while offset < samples.count, !Task.isCancelled {
                let end = min(offset + chunk, samples.count)
                self?.onSamples?(Array(samples[offset..<end]))
                offset = end
                try? await Task.sleep(for: .seconds(0.1 / speed))
            }
            self?.onFinished?()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
