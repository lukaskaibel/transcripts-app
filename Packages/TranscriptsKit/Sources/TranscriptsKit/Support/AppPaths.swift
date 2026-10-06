import Foundation

/// Where the app keeps its files.
public enum AppPaths {
    /// Overridden in tests and in the screenshot/demo mode so they never touch real data.
    nonisolated(unsafe) public static var overrideRoot: URL?

    public static var applicationSupport: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcripts", isDirectory: true)
    }

    public static var recordings: URL {
        applicationSupport.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// The folder with one meeting's audio files.
    public static func folder(for meetingId: String) -> URL {
        recordings.appendingPathComponent(meetingId, isDirectory: true)
    }

    /// The uncompressed file a channel is recorded into.
    public static func rawFile(for meetingId: String, channel: Channel) -> URL {
        folder(for: meetingId).appendingPathComponent(channel == .microphone ? "microphone.caf" : "system.caf")
    }

    /// The compressed file a channel is kept as after processing.
    public static func audioFile(for meetingId: String, channel: Channel) -> URL {
        folder(for: meetingId).appendingPathComponent(channel == .microphone ? "microphone.m4a" : "system.m4a")
    }

    /// Whichever file of a channel exists, preferring the uncompressed one.
    public static func existingAudio(for meetingId: String, channel: Channel) -> URL? {
        [rawFile(for: meetingId, channel: channel), audioFile(for: meetingId, channel: channel)]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The file a meeting was imported from, if it was.
    public static func existingImport(for meetingId: String) -> URL? {
        let folder = folder(for: meetingId)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == "import" }
    }

    /// An imported file is kept as-is next to the derived ones.
    public static func importedFile(for meetingId: String, extension ext: String) -> URL {
        folder(for: meetingId).appendingPathComponent("import.\(ext)")
    }

    public static func sizeOfRecordings() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

/// Words the app uses in several places. The interface is German.
public enum Strings {
    public static let me = "Du"
    public static let untitledMeeting = "Meeting"

    public static func speakerLabel(_ number: Int) -> String { "Sprecher \(number)" }
}
