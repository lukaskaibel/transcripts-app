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
    /// When set, only this channel plays: one voice without the other side of the call talking over it.
    public private(set) var soloChannel: Channel?
    /// Plays without sound, for the screenshot tours.
    @ObservationIgnored public var muted = false

    @ObservationIgnored private var player: AVPlayer?
    /// The stretches still to play after the one playing now, for lines played one after another.
    @ObservationIgnored private var queue: [ClosedRange<Double>] = []
    /// The channel the loaded composition was asked for (nil: all of them).
    @ObservationIgnored private var loadedChannel: Channel?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    public init() {}

    public var isLoaded: Bool { player != nil }

    /// Starts playing `meetingId` at `time`; plays only until `until` when given, and only `channel` when given.
    public func play(meetingId: String, from time: Double, until: Double? = nil, only channel: Channel? = nil) async {
        queue = []
        await start(meetingId: meetingId, from: time, until: until, only: channel)
    }

    /// Plays the stretches one after another, skipping what lies between them.
    public func play(meetingId: String, stretches: [ClosedRange<Double>], only channel: Channel? = nil) async {
        guard let first = stretches.first else { return }
        queue = Array(stretches.dropFirst())
        await start(meetingId: meetingId, from: first.lowerBound, until: first.upperBound, only: channel)
    }

    private func start(meetingId: String, from time: Double, until: Double?, only channel: Channel?) async {
        if self.meetingId != meetingId || player == nil || loadedChannel != channel {
            guard await load(meetingId, only: channel) else { return }
        }
        stopAt = until
        await seek(to: time)
        player?.play()
        isPlaying = true
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            queue = []
            stopAt = nil
            if let meetingId, soloChannel != nil {
                // Carrying on means the whole meeting again, with every channel.
                let time = currentTime
                Task { await play(meetingId: meetingId, from: time) }
                return
            }
            if currentTime >= duration - 0.2 { Task { await seek(to: 0) } }
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
        soloChannel = nil
        loadedChannel = nil
        queue = []
        meetingId = nil
    }

    /// Lays the channels of a meeting on top of each other in one composition, or just the one asked for.
    private func load(_ meetingId: String, only channel: Channel? = nil) async -> Bool {
        let queued = queue
        stop()
        queue = queued
        var files = (channel.map { [$0] } ?? Channel.allCases).compactMap { AppPaths.playbackAudio(for: meetingId, channel: $0) }
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

        #if os(iOS)
        // Played out loud even with the ring switch on silent; while recording, the session is already set up to
        // record and play.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
        }
        #endif
        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        self.player = player
        self.meetingId = meetingId
        // An imported recording has no channels to pick from.
        soloChannel = channel.flatMap { AppPaths.playbackAudio(for: meetingId, channel: $0) == nil ? nil : $0 }
        loadedChannel = channel
        duration = longest.seconds
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                guard let stopAt = self.stopAt, time.seconds >= stopAt else { return }
                self.player?.pause()
                if self.queue.isEmpty {
                    self.isPlaying = false
                    self.stopAt = nil
                } else {
                    let next = self.queue.removeFirst()
                    self.stopAt = next.upperBound
                    Task {
                        await self.seek(to: next.lowerBound)
                        // Unless it was paused or stopped meanwhile.
                        if self.isPlaying, self.stopAt == next.upperBound { self.player?.play() }
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        return true
    }
}
