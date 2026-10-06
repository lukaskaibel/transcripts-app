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
    private var outputListener: AudioObjectPropertyListenerBlock?
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

        guard var streamDescription = CoreAudioHelpers.tapFormat(tap),
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            destroyTap()
            throw AudioError.unsupportedFormat("Systemaudio")
        }
        self.format = format
        resampler = try StreamingResampler(from: format)

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

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
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

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard let format, let resampler,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
        let samples = resampler.convert(buffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    private func destroyTap() {
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
    }

    /// Headphones plugged in or AirPods connected: rebuild the tap on the new output device.
    private func listenForOutputChanges() {
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.lock.withLock {
                self.destroyTap()
                do {
                    try self.createTap()
                } catch {
                    Log.audio.error("Restarting the system audio tap failed: \(error.localizedDescription)")
                }
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func removeOutputListener() {
        guard let outputListener else { return }
        var address = CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
        self.outputListener = nil
    }
}
