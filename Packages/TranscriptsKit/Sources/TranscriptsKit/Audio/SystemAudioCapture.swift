import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures everything the Mac plays (the other side of a call) with a Core Audio process tap.
///
/// The tap leaves the app's own audio out, so playing back a recording never ends up in a new one.
/// Needs "System Audio Recording" permission; macOS asks the first time a tap is created.
public final class SystemAudioCapture: AudioSource, @unchecked Sendable {
    /// Called on a private queue with 16 kHz mono samples.
    public var onSamples: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "Transcripts.SystemAudio", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: StreamingResampler?
    private var format: AVAudioFormat?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rateListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    /// The rate the buffers are read at; its own lock, so the rate listener never waits for a rebuild.
    private let readRate = OSAllocatedUnfairLock(initialState: Float64(0))
    private var running = false

    public init() {}

    public func start() throws {
        try lock.withLock { try createTap() }
        running = true
        listenForOutputChanges()
    }

    public func stop() {
        running = false
        removeOutputListener()
        lock.withLock { destroyTap() }
    }

    private func createTap() throws {
        let own = CoreAudioHelpers.processObject(for: getpid())
        let excluded = own == AudioObjectID(kAudioObjectUnknown) ? [] : [own]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Transcripts"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AudioError.coreAudio("Das Aufnehmen des Systemaudios", status) }
        tapID = tap

        guard var streamDescription = CoreAudioHelpers.tapFormat(tap) else {
            destroyTap()
            throw AudioError.unsupportedFormat("Systemaudio")
        }

        let outputUID = CoreAudioHelpers.uid(of: CoreAudioHelpers.defaultOutputDevice) ?? ""
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcripts Systemaudio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        if !outputUID.isEmpty {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            destroyTap()
            throw AudioError.coreAudio("Das Einrichten der Systemaudio-Aufnahme", status)
        }
        aggregateID = device

        // The aggregate runs at the rate of its main device (MacBook speakers: 44.1 kHz) and hands over the
        // tap's audio at that rate, whatever the tap's own format says (48 kHz). Read with the tap's rate, the
        // call came out 9 % too fast and too high, with half a second of silence padded in every six seconds.
        let deviceRate: Float64 = CoreAudioHelpers.value(device, kAudioDevicePropertyNominalSampleRate, default: 0)
        if deviceRate > 0, abs(deviceRate - streamDescription.mSampleRate) > 1 {
            Log.audio.info("System audio: tap format says \(streamDescription.mSampleRate) Hz, the device runs at \(deviceRate) Hz")
            streamDescription.mSampleRate = deviceRate
        }
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            destroyTap()
            throw AudioError.unsupportedFormat("Systemaudio")
        }
        self.format = format
        readRate.withLock { $0 = format.sampleRate }
        let converter: StreamingResampler
        do {
            converter = try StreamingResampler(from: format)
        } catch {
            destroyTap()
            throw error
        }
        resampler = converter
        listenForRateChanges(of: device)

        // The aggregate lists the input streams of its sub-device first, then the tap's. The speakers have none,
        // except when some app uses voice processing, which gives them an echo reference stream: so take the
        // tap's buffers from the end, never the first ones.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let list = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        bufferList = list
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            guard let tap = Self.tapBuffers(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), count: tapBuffers) else { return }
            for (index, buffer) in tap.enumerated() {
                list[index] = buffer
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples) }
        }
        guard status == noErr, let procID else {
            destroyTap()
            throw AudioError.coreAudio("Das Starten der Systemaudio-Aufnahme", status)
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            destroyTap()
            throw AudioError.coreAudio("Das Starten der Systemaudio-Aufnahme", status)
        }
    }

    /// The tap's buffers in the aggregate's input: the last `count`, after any streams of the sub-device.
    static func tapBuffers(_ input: UnsafeMutableAudioBufferListPointer, count: Int) -> [AudioBuffer]? {
        guard count > 0, input.count >= count else { return nil }
        return Array(input.suffix(count))
    }

    private func destroyTap() {
        removeRateListener()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        resampler = nil
        format = nil
        // Freed on the IO queue, after any buffer still waiting there.
        if let bufferList {
            queue.async { free(bufferList.unsafeMutablePointer) }
        }
        bufferList = nil
    }

    /// Headphones plugged in or AirPods connected: rebuild the tap on the new output device.
    private func listenForOutputChanges() {
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuild()
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    /// The output device switched to another sample rate: rebuild, so the buffers are read at the new one.
    /// Called with the lock held.
    private func listenForRateChanges(of device: AudioObjectID) {
        var address = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let rate: Float64 = CoreAudioHelpers.value(device, kAudioDevicePropertyNominalSampleRate, default: 0)
            if rate > 0, abs(rate - self.readRate.withLock { $0 }) > 1 { self.rebuild() }
        }
        rateListener = (device, block)
        AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
    }

    private func removeRateListener() {
        guard let (device, block) = rateListener else { return }
        var address = CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        rateListener = nil
    }

    private func rebuild() {
        guard running else { return }
        lock.withLock {
            destroyTap()
            do {
                try createTap()
            } catch {
                Log.audio.error("Restarting the system audio tap failed: \(error.localizedDescription)")
            }
        }
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        self.outputListener = nil
    }
}
