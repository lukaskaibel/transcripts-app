import Foundation

/// A name the language model found for a voice that had none ("Sprecher 3 is Paula").
public struct SpeakerNameHint: Equatable, Sendable {
    public var speakerLabel: String
    public var name: String
    public var evidence: String
}

/// What a summary request produced.
public struct SummaryOutcome: Sendable {
    public var title: String
    public var overview: String
    public var decisions: [String]
    public var actionItems: [(text: String, owner: String?, due: String?)]
    public var openQuestions: [String]
    public var speakerNames: [SpeakerNameHint]
}

/// The running summary shown next to the live transcript.
public struct LiveSummary: Equatable, Sendable {
    public var points: [String]
    public var actionItems: [String]
    public var openQuestions: [String]
    public var updatedAt: Date
}

/// Writes meeting summaries with whichever language model the user chose.
public enum Summarizer {
    static let summarySchema: [String: JSONValue] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "A short, specific title for the meeting, at most six words."],
            "overview": ["type": "string", "description": "Two to four sentences: what the meeting was about and what came out of it."],
            "decisions": ["type": "array", "items": ["type": "string"], "description": "Decisions that were actually made."],
            "actionItems": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The task, short and concrete."],
                        "owner": ["type": "string", "description": "Who will do it, as named in the transcript, or an empty string."],
                        "due": ["type": "string", "description": "When, as said in the meeting (\"Mittwoch\", \"14. Oktober\"), or an empty string."],
                    ],
                    "required": ["text", "owner", "due"],
                    "additionalProperties": false,
                ],
            ],
            "openQuestions": ["type": "array", "items": ["type": "string"], "description": "Questions left open."],
            "speakerNames": [
                "type": "array",
                "description": "Only for speakers labelled like \"Sprecher 2\": their name, if the conversation reveals it.",
                "items": [
                    "type": "object",
                    "properties": [
                        "speaker": ["type": "string", "description": "The label exactly as in the transcript."],
                        "name": ["type": "string"],
                        "evidence": ["type": "string", "description": "The sentence from the transcript that reveals the name."],
                    ],
                    "required": ["speaker", "name", "evidence"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["title", "overview", "decisions", "actionItems", "openQuestions", "speakerNames"],
        "additionalProperties": false,
    ]

    static let liveSchema: [String: JSONValue] = [
        "type": "object",
        "properties": [
            "points": ["type": "array", "items": ["type": "string"]],
            "actionItems": ["type": "array", "items": ["type": "string"]],
            "openQuestions": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["points", "actionItems", "openQuestions"],
        "additionalProperties": false,
    ]

    static func systemPrompt(myName: String, language: SummaryLanguage) -> String {
        """
        You summarize meetings for the person who recorded them, \(myName). You get a transcript with timestamps \
        and speaker names; voices whose name is unknown are labelled "Sprecher 1", "Sprecher 2" and so on.

        Write every field in the language the meeting was held in (a German meeting gets a German summary). Be brief \
        and factual and stay with what was said: no assumptions, no advice, no filler. Use the names from the \
        transcript for owners. Leave lists empty when there is nothing for them. Speech recognition makes small \
        mistakes; read past them.

        Answer with a single JSON object that follows the schema, and nothing else.\(languageRule(language))
        """
    }

    static func languageRule(_ language: SummaryLanguage) -> String {
        switch language {
        case .meeting: ""
        case .german: "\n\nWrite all fields in German, whatever language the meeting was held in."
        case .english: "\n\nWrite all fields in English, whatever language the meeting was held in."
        }
    }

    /// The transcript as the model reads it, with real names wherever they are known.
    public static func transcriptText(_ detail: MeetingDetail, myName: String) -> String {
        detail.segments.map { segment in
            let name = segment.speakerKey == MeetingSpeaker.meKey ? myName : detail.displayName(for: segment.speakerKey)
            return "[\(TimeFormat.clock(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    static func header(_ detail: MeetingDetail) -> String {
        var lines = ["Meeting: \(detail.meeting.title)", "Datum: \(TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration))"]
        if !detail.meeting.attendees.isEmpty {
            lines.append("Eingeladen laut Kalender: " + detail.meeting.attendees.map(\.name).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func summarize(_ detail: MeetingDetail, myName: String, language: SummaryLanguage = .meeting, provider: LLMProvider, model: String) async throws -> SummaryOutcome {
        let transcript = transcriptText(detail, myName: myName)
        guard !transcript.isEmpty else { throw LLMError.badResponse("Das Transkript ist leer.") }
        let budget = max(provider.contextCharacters - 6_000, 8_000)
        if transcript.count <= budget {
            let prompt = "\(header(detail))\n\nTranskript:\n\(transcript)"
            return try await request(prompt, myName: myName, language: language, provider: provider, model: model)
        }

        // Too long for one request: summarise consecutive parts, then merge the parts.
        let parts = chunks(transcript, size: budget)
        var partials: [String] = []
        for (index, part) in parts.enumerated() {
            let prompt = "\(header(detail))\n\nTeil \(index + 1) von \(parts.count) des Transkripts:\n\(part)"
            let outcome = try await request(prompt, myName: myName, language: language, provider: provider, model: model)
            partials.append(encode(outcome))
        }
        let prompt = """
        \(header(detail))

        Das sind Zusammenfassungen aufeinanderfolgender Teile desselben Meetings als JSON. Fasse sie zu einer \
        einzigen Zusammenfassung zusammen, ohne Wiederholungen:

        \(partials.joined(separator: "\n\n"))
        """
        return try await request(prompt, myName: myName, language: language, provider: provider, model: model)
    }

    private static func request(_ prompt: String, myName: String, language: SummaryLanguage, provider: LLMProvider, model: String) async throws -> SummaryOutcome {
        let text = try await provider.complete(LLMRequest(system: systemPrompt(myName: myName, language: language), prompt: prompt, schema: summarySchema), model: model)
        return try parse(text)
    }

    static func parse(_ text: String) throws -> SummaryOutcome {
        let json = try JSONExtraction.object(from: text)
        func strings(_ key: String) -> [String] {
            (json[key]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func optional(_ value: JSONValue?) -> String? {
            guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !["null", "none", "-", "unbekannt", "unknown", "n/a"].contains(text.lowercased()) else { return nil }
            return text
        }
        let items = (json["actionItems"]?.array ?? []).compactMap { item -> (String, String?, String?)? in
            if let text = item.string { return (text, nil, nil) }
            guard let text = optional(item["text"]) else { return nil }
            return (text, optional(item["owner"]), optional(item["due"]))
        }
        let names = (json["speakerNames"]?.array ?? []).compactMap { item -> SpeakerNameHint? in
            guard let label = optional(item["speaker"]), let name = optional(item["name"]) else { return nil }
            return SpeakerNameHint(speakerLabel: label, name: name, evidence: optional(item["evidence"]) ?? "")
        }
        guard let overview = optional(json["overview"]) else { throw LLMError.badResponse("Die Zusammenfassung fehlt.") }
        return SummaryOutcome(
            title: optional(json["title"]) ?? "",
            overview: overview,
            decisions: strings("decisions"),
            actionItems: items.map { (text: $0.0, owner: $0.1, due: $0.2) },
            openQuestions: strings("openQuestions"),
            speakerNames: names
        )
    }

    private static func encode(_ outcome: SummaryOutcome) -> String {
        let value: JSONValue = [
            "overview": .string(outcome.overview),
            "decisions": .array(outcome.decisions.map { .string($0) }),
            "actionItems": .array(outcome.actionItems.map { ["text": .string($0.text), "owner": .string($0.owner ?? ""), "due": .string($0.due ?? "")] }),
            "openQuestions": .array(outcome.openQuestions.map { .string($0) }),
            "speakerNames": .array(outcome.speakerNames.map { ["speaker": .string($0.speakerLabel), "name": .string($0.name), "evidence": .string($0.evidence)] }),
        ]
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Splits at line boundaries into pieces of at most `size` characters.
    static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Live

    public static func summarizeLive(transcript: String, myName: String, language: SummaryLanguage = .meeting, provider: LLMProvider, model: String) async throws -> LiveSummary {
        let budget = max(provider.contextCharacters - 4_000, 8_000)
        let text = transcript.count > budget ? String(transcript.suffix(budget)) : transcript
        let system = """
        You follow a meeting that is still running, for \(myName). From the transcript so far, list what has been \
        discussed (at most six short points), the tasks mentioned so far, and the questions that are still open. \
        Write in the meeting's language, in short phrases. Answer with a single JSON object that follows the schema.\(languageRule(language))
        """
        let answer = try await provider.complete(LLMRequest(system: system, prompt: "Transkript bisher:\n\(text)", schema: liveSchema, maxOutputTokens: 4_000), model: model)
        let json = try JSONExtraction.object(from: answer)
        func strings(_ key: String) -> [String] {
            (json[key]?.array ?? []).compactMap { $0.string ?? $0["text"]?.string }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return LiveSummary(points: strings("points"), actionItems: strings("actionItems"), openQuestions: strings("openQuestions"), updatedAt: Date())
    }
}
