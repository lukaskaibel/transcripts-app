import os

enum Log {
    static let audio = Logger(subsystem: "com.lukaskbl.Transcripts", category: "audio")
    static let speech = Logger(subsystem: "com.lukaskbl.Transcripts", category: "speech")
    static let pipeline = Logger(subsystem: "com.lukaskbl.Transcripts", category: "pipeline")
    static let ai = Logger(subsystem: "com.lukaskbl.Transcripts", category: "ai")
    static let calendar = Logger(subsystem: "com.lukaskbl.Transcripts", category: "calendar")
    static let app = Logger(subsystem: "com.lukaskbl.Transcripts", category: "app")
}
