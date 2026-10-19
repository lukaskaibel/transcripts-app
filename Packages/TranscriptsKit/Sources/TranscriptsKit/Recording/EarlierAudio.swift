import Foundation

/// The audio of a meeting when more of it is recorded: what was recorded before goes to the front of the new
/// recording files, both channels padded to the same length, so the meeting goes on from where it stopped and the
/// pass afterwards hears it as one recording.
enum EarlierAudio {
    /// A channel's earlier file, while the new recording file takes its place.
    struct Source {
        var url: URL
        /// The earlier file was a recording file (the meeting wasn't processed yet), moved out of the way.
        var setAside: Bool
    }

    static func setAsideFile(for meetingId: String, channel: Channel) -> URL {
        AppPaths.folder(for: meetingId).appendingPathComponent(channel == .microphone ? "microphone-earlier.caf" : "system-earlier.caf")
    }

    /// Each channel's earlier audio. A recording file is moved aside first: the new one is written where it was.
    static func setAside(meetingId: String, channels: [Channel]) throws -> [Channel: Source] {
        var sources: [Channel: Source] = [:]
        do {
            for channel in channels {
                let raw = AppPaths.rawFile(for: meetingId, channel: channel)
                if FileManager.default.fileExists(atPath: raw.path) {
                    let aside = setAsideFile(for: meetingId, channel: channel)
                    try? FileManager.default.removeItem(at: aside)
                    try FileManager.default.moveItem(at: raw, to: aside)
                    sources[channel] = Source(url: aside, setAside: true)
                } else if let compressed = AppPaths.existingAudio(for: meetingId, channel: channel) {
                    sources[channel] = Source(url: compressed, setAside: false)
                }
            }
        } catch {
            restore(sources, meetingId: meetingId)
            throw error
        }
        return sources
    }

    /// Writes the earlier audio into the new files, then silence into the shorter ones up to the longest. Returns
    /// where the new recording starts in the meeting, in seconds.
    static func copy(_ sources: [Channel: Source], into writers: [Channel: AudioFileWriter]) throws -> TimeInterval {
        for (channel, writer) in writers {
            guard let source = sources[channel] else { continue }
            try SpeechAudio.read(source.url) { try writer.write($0) }
        }
        let length = writers.values.map(\.samplesWritten).max() ?? 0
        let chunk = SpeechAudio.samples(30)
        for writer in writers.values {
            while writer.samplesWritten < length {
                try writer.write([Float](repeating: 0, count: min(chunk, length - writer.samplesWritten)))
            }
        }
        return SpeechAudio.seconds(length)
    }

    /// The copy is done: the moved files go, and so does the microphone without echo, which only covers the part
    /// before (the pass afterwards makes a new one).
    static func finish(_ sources: [Channel: Source], meetingId: String) {
        for source in sources.values where source.setAside {
            try? FileManager.default.removeItem(at: source.url)
        }
        try? FileManager.default.removeItem(at: AppPaths.cleanedMicrophoneFile(for: meetingId))
    }

    /// The new recording couldn't start: the moved files go back where they were.
    static func restore(_ sources: [Channel: Source], meetingId: String) {
        for (channel, source) in sources where source.setAside {
            let raw = AppPaths.rawFile(for: meetingId, channel: channel)
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.moveItem(at: source.url, to: raw)
        }
    }

    /// After the app quit while the earlier audio was being copied: the moved file is the whole of it, the new
    /// recording file only a part.
    static func recover(meetingId: String) {
        for channel in Channel.allCases {
            let aside = setAsideFile(for: meetingId, channel: channel)
            guard FileManager.default.fileExists(atPath: aside.path) else { continue }
            let raw = AppPaths.rawFile(for: meetingId, channel: channel)
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.moveItem(at: aside, to: raw)
        }
    }
}
