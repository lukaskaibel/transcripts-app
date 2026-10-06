import AVFoundation
import Foundation
import os
import Testing
@testable import TranscriptsKit

/// A sine tone of `seconds` at 16 kHz.
private func tone(seconds: Double, frequency: Float = 440, amplitude: Float = 0.3) -> [Float] {
    let count = SpeechAudio.samples(seconds)
    return (0..<count).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(SpeechAudio.sampleRate)) }
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AudioTests {
    @Test func meterLevelSpansSilenceToLoud() {
        #expect(SpeechAudio.meterLevel([Float](repeating: 0, count: 1600)) == 0)
        #expect(SpeechAudio.meterLevel(tone(seconds: 0.1, amplitude: 0.9)) == 1)
        let quiet = SpeechAudio.meterLevel(tone(seconds: 0.1, amplitude: 0.01))
        #expect(quiet > 0 && quiet < 0.6)
    }

    @Test func recordingFileReadsBackWhatWasWritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.caf")
        let samples = tone(seconds: 1.5)
        let writer = try AudioFileWriter(url: url)
        // Written in pieces, like a recording.
        for start in stride(from: 0, to: samples.count, by: 1000) {
            try writer.write(Array(samples[start..<min(start + 1000, samples.count)]))
        }
        writer.close()

        let loaded = try SpeechAudio.load(url)
        #expect(loaded.count == samples.count)
        #expect(abs(SpeechAudio.rms(loaded) - SpeechAudio.rms(samples)) < 0.01)
        #expect(abs(SpeechAudio.duration(of: url) - 1.5) < 0.01)
    }

    @Test func resamplerTurns48kStereoInto16kMono() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let resampler = try StreamingResampler(from: format)
        var total = 0
        for _ in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for channel in 0..<2 {
                for i in 0..<4800 { buffer.floatChannelData![channel][i] = 0.3 * sin(Float(i) * 0.05) }
            }
            total += resampler.convert(buffer).count
        }
        total += resampler.flush().count
        // One second at 48 kHz is one second at 16 kHz.
        #expect(abs(total - 16_000) < 200)
    }

    @Test func fileSourcePlaysEverySampleOnce() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.caf")
        let samples = tone(seconds: 2)
        let writer = try AudioFileWriter(url: url)
        try writer.write(samples)
        writer.close()

        let source = try FileAudioSource(url: url, speed: 200)
        #expect(abs(source.duration - 2) < 0.01)
        let received = OSAllocatedUnfairLock(initialState: [Float]())
        source.onSamples = { chunk in received.withLock { $0 += chunk } }
        await withCheckedContinuation { continuation in
            source.onFinished = { continuation.resume() }
            try? source.start()
        }
        #expect(received.withLock { $0.count } == samples.count)
    }
}

@Suite(.serialized) struct AudioArchiverTests {
    @Test func compressingKeepsTheLengthAndDropsTheRecordingFile() throws {
        let root = try temporaryFolder()
        AppPaths.overrideRoot = root
        defer {
            AppPaths.overrideRoot = nil
            try? FileManager.default.removeItem(at: root)
        }
        let meetingId = "archive-test"
        let raw = AppPaths.rawFile(for: meetingId, channel: .microphone)
        let writer = try AudioFileWriter(url: raw)
        try writer.write(tone(seconds: 10))
        writer.close()
        #expect(AudioArchiver.hasAudio(meetingId: meetingId))

        try AudioArchiver.compress(meetingId: meetingId)

        let compressed = AppPaths.audioFile(for: meetingId, channel: .microphone)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(abs(SpeechAudio.duration(of: compressed) - 10) < 0.1)
        #expect(AppPaths.existingAudio(for: meetingId, channel: .microphone) == compressed)
        let size = (try FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? .max
        // At most a third of the 16-bit original (a fixed header makes short files relatively larger).
        #expect(size < 10 * 16_000 * 2 / 3, "compressed to \(size) bytes")

        AudioArchiver.deleteAudio(meetingId: meetingId)
        #expect(!AudioArchiver.hasAudio(meetingId: meetingId))
    }
}

@Suite struct SystemAudioTests {
    @Test func theTapsBuffersAreTheLastOnes() {
        // With voice processing on somewhere, the speakers bring a 6-channel echo reference stream into the
        // aggregate, ahead of the tap's stereo stream.
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 6, mDataByteSize: 6 * 4 * 512, mData: nil)
        list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 2 * 4 * 512, mData: nil)
        #expect(SystemAudioCapture.tapBuffers(list, count: 1)?.map(\.mNumberChannels) == [2])
        #expect(SystemAudioCapture.tapBuffers(list, count: 2)?.map(\.mNumberChannels) == [6, 2])
        #expect(SystemAudioCapture.tapBuffers(list, count: 3) == nil)

        let alone = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(alone.unsafeMutablePointer) }
        alone[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 2 * 4 * 512, mData: nil)
        #expect(SystemAudioCapture.tapBuffers(alone, count: 1)?.map(\.mNumberChannels) == [2])
    }
}
