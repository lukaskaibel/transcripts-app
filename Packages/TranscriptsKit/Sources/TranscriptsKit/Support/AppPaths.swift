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

    /// The microphone without the call's echo, made after the meeting; played instead of the recording.
    public static func cleanedMicrophoneFile(for meetingId: String) -> URL {
        folder(for: meetingId).appendingPathComponent("microphone-clean.m4a")
    }

    /// A call track as first recorded, kept when it was repaired (see `CallTrackRepair`).
    public static func originalSystemFile(for meetingId: String, extension ext: String = "m4a") -> URL {
        folder(for: meetingId).appendingPathComponent("system-original.\(ext)")
    }

    /// What to play for a channel: the microphone without echo where there is such a version.
    public static func playbackAudio(for meetingId: String, channel: Channel) -> URL? {
        if channel == .microphone {
            let cleaned = cleanedMicrophoneFile(for: meetingId)
            if FileManager.default.fileExists(atPath: cleaned.path) { return cleaned }
        }
        return existingAudio(for: meetingId, channel: channel)
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

/// Words the app uses in several places.
///
/// Some are stored with a meeting (a voice's label, the reason for a suggestion) and compared in code, so they are
/// stored in German, the language the app's texts are written in, and shown in the interface's language through
/// `label(_:)` and `reason(_:)`.
public enum Strings {
    /// How the user is called in their own meetings.
    public static var me: String { String(localized: "Du") }
    /// The label the user's own voice is stored with.
    public static let meLabel = "Du"

    /// The label a voice without a name is stored with ("Sprecher 2"); `label(_:)` shows it.
    public static func speakerLabel(_ number: Int) -> String { "Sprecher \(number)" }

    /// A stored label in the interface's language: "Sprecher 2" becomes "Speaker 2", "Du" becomes "You".
    public static func label(_ stored: String) -> String {
        if stored == meLabel { return me }
        if let number = number(inLabel: stored) { return String(localized: "Sprecher \(number)") }
        return stored
    }

    /// 2 for "Sprecher 2".
    public static func number(inLabel label: String) -> Int? {
        guard label.hasPrefix("Sprecher ") else { return nil }
        return Int(label.dropFirst("Sprecher ".count))
    }

    /// "Hai", "Hai oder Julian", "Hai, Julian oder Sven", in the interface's language.
    public static func alternatives(_ names: [String]) -> String {
        names.formatted(.list(type: .or).locale(AppLocale.current))
    }

    /// A stored reason for a suggestion in the interface's language: "Stimme ähnlich wie in 2 früheren Meetings"
    /// becomes "Voice like in 2 earlier meetings", and a quote gets the language's quotation marks.
    public static func reason(_ stored: String) -> String {
        if stored == SpeakerIdentifier.conversationReason { return String(localized: "Aus dem Gesprächsverlauf") }
        if let meetings = SpeakerIdentifier.meetings(inVoiceReason: stored) {
            return String(localized: "Stimme ähnlich wie in \(meetings) früheren Meetings")
        }
        return quoted(stored)
    }

    /// `text` in the quotation marks of the interface's language: „…“, “…”, « … ».
    public static func quote(_ text: String) -> String {
        let locale = AppLocale.current
        return (locale.quotationBeginDelimiter ?? "“") + text + (locale.quotationEndDelimiter ?? "”")
    }

    /// „…“ in a stored text with the quotation marks of the interface's language.
    static func quoted(_ text: String) -> String {
        guard let open = text.firstIndex(of: "„"), let close = text.lastIndex(of: "“"), open < close else { return text }
        let locale = AppLocale.current
        let begin = locale.quotationBeginDelimiter ?? "“", end = locale.quotationEndDelimiter ?? "”"
        return String(text[..<open]) + begin + text[text.index(after: open)..<close] + end + text[text.index(after: close)...]
    }
}
