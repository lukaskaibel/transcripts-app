import AudioToolbox
import AVFoundation
import Foundation

/// Captures the microphone with AVAudioEngine and hands out 16 kHz mono samples.
public final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    /// Called on an audio thread with 16 kHz mono samples.
    public var onSamples: (([Float]) -> Void)?

    /// The microphone to use, by Core Audio UID; nil follows the system's default input.
    public var deviceUID: String?
    /// Apple's echo cancellation. Helps when the call plays through speakers instead of headphones.
    public var voiceProcessing = false

    private var engine = AVAudioEngine()
    private var resampler: StreamingResampler?
    private var configurationObserver: NSObjectProtocol?
    private var running = false

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
        case .denied, .restricted: throw AudioError.permissionDenied("das Mikrofon")
        default: break
        }
        try configureAndStart()
        running = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    public func stop() {
        running = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func configureAndStart() throws {
        let input = engine.inputNode
        if let deviceUID, let device = CoreAudioHelpers.device(withUID: deviceUID), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if voiceProcessing != input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(voiceProcessing)
            if voiceProcessing {
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min
                )
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
        let resampler = try StreamingResampler(from: format)
        self.resampler = resampler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self?.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    /// The input device or its format changed (a headset was plugged in): start over with the new one.
    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        do {
            try configureAndStart()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.restart()
            }
        } catch {
            Log.audio.error("Restarting the microphone failed: \(error.localizedDescription)")
        }
    }
}
