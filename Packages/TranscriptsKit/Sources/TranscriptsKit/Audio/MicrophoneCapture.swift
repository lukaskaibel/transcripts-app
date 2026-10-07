import AudioToolbox
import AVFoundation
import Foundation
import os

/// Captures the microphone with AVAudioEngine and hands out 16 kHz mono samples.
public final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    /// Called on an audio thread with 16 kHz mono samples.
    public var onSamples: (([Float]) -> Void)?

    /// The microphone to use, by Core Audio UID; nil follows the system's default input.
    public var deviceUID: String?

    private var engine = AVAudioEngine()
    private var resampler: StreamingResampler?
    private var configurationObserver: NSObjectProtocol?
    private var running = false
    private let lastDelivery = OSAllocatedUnfairLock(initialState: Date.distantPast)
    private var watchdog: Timer?
    private var lastRestart = Date.distantPast

    public init() {}

    public static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    @discardableResult
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        switch Self.permission {
        case .denied, .restricted: throw AudioError.permissionDenied(String(localized: "Kein Zugriff auf das Mikrofon. Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit."))
        default: break
        }
        try configureAndStart()
        running = true
        observeConfigurationChanges()
        // An engine can stop delivering without a word (a reconfiguration that didn't finish, a device that
        // went away): start it again rather than record nothing.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            let quietFor = Date().timeIntervalSince(self.lastDelivery.withLock { $0 })
            if quietFor > 2, Date().timeIntervalSince(self.lastRestart) > 3 {
                Log.audio.error("The microphone delivered nothing for \(quietFor, format: .fixed(precision: 1)) s; restarting it")
                self.restart()
            }
        }
    }

    public func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func observeConfigurationChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    private func configureAndStart() throws {
        let input = engine.inputNode
        if let deviceUID, let device = CoreAudioHelpers.device(withUID: deviceUID), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // No voice processing (Apple's echo cancellation): it ducks the call, adds an echo reference stream to the
        // speakers that the system audio tap then picks up, and with only the input in use it records silence.
        // Echoes of the call in the microphone are dropped from the transcript instead.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
        let resampler = try StreamingResampler(from: format)
        self.resampler = resampler
        lastDelivery.withLock { $0 = Date() }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lastDelivery.withLock { $0 = Date() }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    /// The input device or its format changed (a headset was plugged in), or the engine went quiet: start over.
    private func restart() {
        guard running else { return }
        lastRestart = Date()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do {
            try configureAndStart()
            observeConfigurationChanges()
        } catch {
            Log.audio.error("Restarting the microphone failed: \(error.localizedDescription)")
        }
    }
}
