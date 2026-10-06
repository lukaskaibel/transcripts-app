import Foundation
import TranscriptsKit

// A command line for the pipeline, for testing it on real audio without the app.
//
//   transcripts-cli models [--model ultra]
//   transcripts-cli transcribe <file>
//   transcripts-cli diarize <file>
//   transcripts-cli live <file> [--channel system|microphone]
//   transcripts-cli record --mic <file> --system <file> [--speed 4]   (a whole recording, played from files)
//   transcripts-cli process [--mic <file>] [--system <file>] [--import <file>] [--root <dir>] [--attendees "A, B"] [--title T]
//   transcripts-cli confirm --root <dir> --meeting <id> --assign "S1=Anna Berger, S2=Thomas Klein"
//   transcripts-cli summarize --root <dir> --meeting <id> --provider ollama|anthropic|openai|google [--model M] [--url U]

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options[key] = arguments[index + 1]
                    index += 2
                } else {
                    options[key] = "true"
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    subscript(_ key: String) -> String? { options[key] }
}

/// What the live command collects from the transcriber's callbacks.
final class LiveLog: @unchecked Sendable {
    let lock = NSLock()
    var tracker = LiveSpeakerTracker()
    var finals = 0
}

/// Prints each processing step once.
final class StepPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func show(_ step: String, _ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard step != last else { return }
        last = step
        print(String(format: "  … %@ (%d %%)", step, Int(fraction * 100)))
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func environment(_ key: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { fail("\(key) missing") }
    return value
}

func seconds(since start: Date) -> String {
    String(format: "%.2f s", Date().timeIntervalSince(start))
}

let all = Array(CommandLine.arguments.dropFirst())
guard let command = all.first else { fail("usage: transcripts-cli <models|transcribe|diarize|live|record|process|confirm|summarize> …") }
let args = Arguments(Array(all.dropFirst()))
let model = TranscriptionModel(rawValue: args["model"] ?? "ultra") ?? .ultra
let engine = SpeechEngine.shared

func prepare() async {
    let start = Date()
    let steps = StepPrinter()
    do {
        try await engine.prepare(model: model) { state in
            if case .preparing(let step, let fraction) = state {
                steps.show(step, fraction)
            }
        }
    } catch {
        fail("Preparing the models failed: \(error.localizedDescription)")
    }
    print("Models ready (\(model.title)) in \(seconds(since: start))")
}

switch command {
case "models":
    await prepare()

case "transcribe":
    guard let path = args.positional.first else { fail("transcribe <file>") }
    await prepare()
    var audio = try SpeechAudio.load(URL(fileURLWithPath: path))
    if let from = args["from"].flatMap(Double.init), let to = args["to"].flatMap(Double.init) {
        audio = Array(audio[SpeechAudio.samples(from)..<min(audio.count, SpeechAudio.samples(to))])
    }
    let start = Date()
    let result = try await engine.transcribe(audio)
    print("Transcribed \(String(format: "%.1f", SpeechAudio.seconds(audio.count))) s of audio in \(seconds(since: start))")
    print(result.text)
    print("\(result.words.count) words; first: \(result.words.prefix(5).map { "\($0.text)@\(String(format: "%.2f", $0.start))" })")
    if let range = args["words"]?.split(separator: "-").compactMap({ Double($0) }), range.count == 2 {
        for word in result.words where word.start >= range[0] && word.start <= range[1] {
            print(String(format: "  %7.2f – %7.2f  %@", word.start, word.end, word.text))
        }
    }

case "diarize":
    guard let path = args.positional.first else { fail("diarize <file>") }
    await prepare()
    let audio = try SpeechAudio.load(URL(fileURLWithPath: path))
    let start = Date()
    let result = try await engine.diarize(audio, threshold: args["threshold"].flatMap(Double.init), minSpeakers: args["min"].flatMap(Int.init))
    print("Diarized in \(seconds(since: start)): \(Set(result.turns.map(\.speaker)).count) speakers, \(result.turns.count) turns")
    for turn in result.turns {
        print(String(format: "  %7.2f – %7.2f  %@", turn.start, turn.end, turn.speaker))
    }

case "live":
    guard let path = args.positional.first else { fail("live <file>") }
    await prepare()
    let channel = Channel(rawValue: args["channel"] ?? "system") ?? .system
    let audio = try SpeechAudio.load(URL(fileURLWithPath: path))
    let log = LiveLog()
    let transcriber = LiveTranscriber(channel: channel, engine: engine) { event in
        log.lock.lock()
        defer { log.lock.unlock() }
        switch event {
        case .partial(_, let start, let text):
            print(String(format: "  [partial %6.2f] %@", start, text))
        case .final(_, let start, let end, let text, let speaker, let embedding, _):
            let key = speaker ?? embedding.map { log.tracker.assign($0, duration: end - start) } ?? "?"
            log.finals += 1
            print(String(format: "  [final %6.2f–%6.2f %@] %@", start, end, key, text))
        case .silence:
            break
        }
    }
    let start = Date()
    let chunk = SpeechAudio.samples(0.1)
    var offset = 0
    while offset < audio.count {
        let end = min(offset + chunk, audio.count)
        await transcriber.feed(Array(audio[offset..<end]))
        offset = end
    }
    await transcriber.finish()
    try await Task.sleep(for: .milliseconds(300))
    print("Live pass over \(String(format: "%.1f", SpeechAudio.seconds(audio.count))) s took \(seconds(since: start)); \(log.finals) utterances, \(log.tracker.voices.count) voices")

case "process":
    let root = URL(fileURLWithPath: args["root"] ?? NSTemporaryDirectory() + "transcripts-cli-\(UUID().uuidString.prefix(8))")
    AppPaths.overrideRoot = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try AppDatabase.openShared(at: root)
    let attendees = (args["attendees"] ?? "").split(separator: ",").map { Attendee(name: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty }
    let isImport = args["import"] != nil
    let meeting = Meeting(title: args["title"] ?? "Test", status: .processing, origin: isImport ? .importedFile : .recording, attendees: attendees)
    try database.save(meeting)
    let folder = AppPaths.folder(for: meeting.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let mic = args["mic"] { try FileManager.default.copyItem(at: URL(fileURLWithPath: mic), to: AppPaths.rawFile(for: meeting.id, channel: .microphone)) }
    if let system = args["system"] { try FileManager.default.copyItem(at: URL(fileURLWithPath: system), to: AppPaths.rawFile(for: meeting.id, channel: .system)) }
    if let file = args["import"] {
        let url = URL(fileURLWithPath: file)
        try FileManager.default.copyItem(at: url, to: AppPaths.importedFile(for: meeting.id, extension: url.pathExtension))
    }
    await prepare()
    let processor = MeetingProcessor(database: database, engine: engine)
    let start = Date()
    let steps = StepPrinter()
    try await processor.process(meetingId: meeting.id, options: .init(model: model, defaultMyName: args["me"] ?? "Lukas")) { step, fraction in
        steps.show(step, fraction)
    }
    print("Processed in \(seconds(since: start)). Meeting \(meeting.id), root \(root.path)")
    guard let detail = try database.detail(of: meeting.id) else { fail("no detail") }
    print("Language: \(detail.meeting.language ?? "?"), duration \(TimeFormat.duration(detail.meeting.duration))")
    print("Speakers:")
    for speaker in detail.speakers {
        let person = speaker.personId.flatMap { detail.people[$0]?.name } ?? "-"
        let suggestion = speaker.suggestedPersonId.flatMap { detail.people[$0]?.name } ?? speaker.suggestedName ?? "-"
        print("  \(speaker.key) \(speaker.label) · \(speaker.assignment.rawValue) · person \(person) · suggestion \(suggestion) · \(speaker.suggestionReason ?? "") · talk \(String(format: "%.1f", speaker.talkTime)) s")
    }
    print("Transcript:")
    for segment in detail.segments {
        print(String(format: "  [%6.2f] %@: %@", segment.start, detail.displayName(for: segment.speakerKey), segment.text))
    }

case "record":
    // record --mic <file> --system <file> [--speed 4] [--root <dir>]: a full recording from files.
    let root = URL(fileURLWithPath: args["root"] ?? NSTemporaryDirectory() + "transcripts-record-\(UUID().uuidString.prefix(8))")
    AppPaths.overrideRoot = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try AppDatabase.openShared(at: root)
    await prepare()
    let speed = args["speed"].flatMap(Double.init) ?? 4
    var files: [Channel: FileAudioSource] = [:]
    if let mic = args["mic"] { files[.microphone] = try FileAudioSource(url: URL(fileURLWithPath: mic), speed: speed) }
    if let system = args["system"] { files[.system] = try FileAudioSource(url: URL(fileURLWithPath: system), speed: speed) }
    let length = files.values.map(\.duration).max() ?? 0
    // Stop like a person would: once everything was played, plus a moment of silence.
    let finished = AsyncStream<Void> { continuation in
        for source in files.values { source.onFinished = { continuation.yield() } }
    }
    let meeting = Meeting(title: "Aufnahme aus Dateien", status: .recording)
    try database.save(meeting)
    let session = RecordingSession(meeting: meeting, database: database, configuration: .init(), sources: files)
    let started = Date()
    try await session.start()
    print("Recording \(String(format: "%.1f", length)) s at \(speed)× …")
    var done = 0
    for await _ in finished {
        done += 1
        if done == files.count { break }
    }
    try await Task.sleep(for: .seconds(1))
    await session.stop()
    let lines = session.lines
    let voices = session.voices
    print("Stopped after \(seconds(since: started)); live lines: \(lines.count), voices: \(voices.count)")
    for line in lines {
        print(String(format: "  live [%6.2f] %@: %@", line.start, session.displayName(for: line.speakerKey), line.text))
    }
    for voice in voices.values.sorted(by: { $0.key < $1.key }) {
        print("  live voice \(voice.key): \(voice.name ?? voice.label)\(voice.suggestedName.map { " (vielleicht \($0))" } ?? ""), \(Int(voice.speech)) s")
    }
    let processor = MeetingProcessor(database: database, engine: engine)
    try await processor.process(meetingId: meeting.id, options: .init(model: model, defaultMyName: "Lukas"))
    guard let detail = try database.detail(of: meeting.id) else { fail("no detail") }
    print("Final: \(detail.segments.count) lines, \(detail.speakers.count) voices, duration \(String(format: "%.1f", detail.meeting.duration)) s, status \(detail.meeting.status.rawValue)")
    for segment in detail.segments {
        print(String(format: "  final [%6.2f] %@: %@", segment.start, detail.displayName(for: segment.speakerKey), segment.text))
    }
    // Like the app: keep the recording compressed, then make sure it can still be processed again.
    try AudioArchiver.compress(meetingId: meeting.id)
    let folder = AppPaths.folder(for: meeting.id)
    let stored = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in stored.sorted() {
        let url = folder.appendingPathComponent(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        print(String(format: "File %@: %.1f s, %d KB", name, SpeechAudio.duration(of: url), size / 1024))
    }
    try await processor.process(meetingId: meeting.id, options: .init(model: model, defaultMyName: "Lukas"))
    guard let again = try database.detail(of: meeting.id) else { fail("no detail") }
    let same = again.segments.map(\.text) == detail.segments.map(\.text)
    print("Processed again from the compressed files: \(again.segments.count) lines, \(again.speakers.count) voices, same text: \(same)")

case "confirm":
    // confirm --root <dir> --meeting <id> --assign "S1=Anna Berger, S2=Thomas Klein"
    guard let rootPath = args["root"], let meetingId = args["meeting"], let pairs = args["assign"] else { fail("confirm --root --meeting --assign") }
    AppPaths.overrideRoot = URL(fileURLWithPath: rootPath)
    let database = try AppDatabase.openShared(at: URL(fileURLWithPath: rootPath))
    guard let detail = try database.detail(of: meetingId) else { fail("no such meeting") }
    for pair in pairs.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let speaker = detail.speaker(for: parts[0]) else { continue }
        let person = try database.person(named: parts[1])
        try database.assign(speaker, to: person.id)
        print("  \(parts[0]) → \(person.name)")
    }
    print("Voiceprints: \(try database.voiceprints().count)")

case "summarize":
    guard let rootPath = args["root"], let meetingId = args["meeting"] else { fail("summarize --root <dir> --meeting <id> --provider <p>") }
    AppPaths.overrideRoot = URL(fileURLWithPath: rootPath)
    let database = try AppDatabase.openShared(at: URL(fileURLWithPath: rootPath))
    guard let detail = try database.detail(of: meetingId) else { fail("no such meeting") }
    let providerKind = ProviderKind(rawValue: args["provider"] ?? "ollama") ?? .ollama
    let provider: LLMProvider
    switch providerKind {
    case .ollama: provider = OllamaProvider(baseURL: URL(string: args["url"] ?? "http://localhost:11434")!)
    case .anthropic: provider = AnthropicProvider(apiKey: environment("ANTHROPIC_API_KEY"))
    case .openAI: provider = OpenAIProvider(apiKey: environment("OPENAI_API_KEY"))
    case .google: provider = GeminiProvider(apiKey: environment("GEMINI_API_KEY"))
    }
    let models = try await provider.models()
    guard let chosen = args["model"] ?? models.first?.id else { fail("no models") }
    print("Models: \(models.prefix(8).map(\.id)) → using \(chosen)")
    let start = Date()
    let outcome = try await Summarizer.summarize(detail, myName: args["me"] ?? "Lukas", provider: provider, model: chosen)
    print("Summarized in \(seconds(since: start))")
    print("Title: \(outcome.title)")
    print("Overview: \(outcome.overview)")
    print("Decisions: \(outcome.decisions)")
    print("Action items: \(outcome.actionItems.map { "\($0.text) [\($0.owner ?? "-"), \($0.due ?? "-")]" })")
    print("Open questions: \(outcome.openQuestions)")
    print("Speaker names: \(outcome.speakerNames.map { "\($0.speakerLabel) → \($0.name) (\($0.evidence))" })")

default:
    fail("unknown command \(command)")
}
