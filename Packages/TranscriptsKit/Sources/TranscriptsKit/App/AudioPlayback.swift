import AVFoundation
import Foundation
import Observation

/// Plays a meeting's recording: both channels together, from any point of the transcript.
@MainActor
@Observable
public final class AudioPlayback {
    public private(set) var meetingId: String?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    /// When set, playback stops at this time (for "play a sample of this voice").
    public private(set) var stopAt: Double?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    public init() {}

    public var isLoaded: Bool { player != nil }

    /// Starts playing `meetingId` at `time`; plays only until `until` when given.
    public func play(meetingId: String, from time: Double, until: Double? = nil) async {
        if self.meetingId != meetingId || player == nil {
            guard await load(meetingId) else { return }
        }
        stopAt = until
        await seek(to: time)
        player?.play()
        isPlaying = true
    }

    public func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.2 { Task { await seek(to: 0) } }
            stopAt = nil
            player.play()
            isPlaying = true
        }
    }

    public func seek(to time: Double) async {
        guard let player else { return }
        let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target.seconds
    }

    public func skip(_ seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    public func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopAt = nil
        meetingId = nil
    }

    /// Lays the channels of a meeting on top of each other in one composition.
    private func load(_ meetingId: String) async -> Bool {
        stop()
        var files = Channel.allCases.compactMap { AppPaths.existingAudio(for: meetingId, channel: $0) }
        if files.isEmpty, let imported = AppPaths.existingImport(for: meetingId) { files = [imported] }
        guard !files.isEmpty else { return false }

        let composition = AVMutableComposition()
        var longest = CMTime.zero
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange),
                  let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? compositionTrack.insertTimeRange(range, of: track, at: .zero)
            if range.duration > longest { longest = range.duration }
        }
        guard longest > .zero else { return false }

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.meetingId = meetingId
        duration = longest.seconds
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if let stopAt = self.stopAt, time.seconds >= stopAt {
                    self.player?.pause()
                    self.isPlaying = false
                    self.stopAt = nil
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        return true
    }
}
