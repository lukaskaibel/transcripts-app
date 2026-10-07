import Foundation

/// What the language model proposes for one task once its repository is known.
public struct IssueSuggestion: Equatable, Sendable {
    public var index: Int
    /// False when the task is not work for this repository (hiring, organising, …).
    public var include: Bool
    /// Why not, in a few words.
    public var reason: String?
    /// Label names from the repository's own labels.
    public var labels: [String]
    /// One or two sentences of context from the meeting.
    public var context: String
    public var quote: String
    public var quoteSpeaker: String
    public var quoteTime: String
    /// The due date spelled out ("Mittwoch, 8. Oktober"), when the meeting set one.
    public var due: String

    public init(index: Int, include: Bool = true, reason: String? = nil, labels: [String] = [], context: String = "", quote: String = "", quoteSpeaker: String = "", quoteTime: String = "", due: String = "") {
        self.index = index
        self.include = include
        self.reason = reason
        self.labels = labels
        self.context = context
        self.quote = quote
        self.quoteSpeaker = quoteSpeaker
        self.quoteTime = quoteTime
        self.due = due
    }
}

/// Prepares the tasks of a meeting as GitHub issues: labels, whether they belong in the repository, and a short
/// description with a quote. One request per meeting and repository.
public enum IssueDrafter {
    static let schema: [String: JSONValue] = [
        "type": "object",
        "properties": [
            "tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "index": ["type": "integer"],
                        "include": ["type": "boolean", "description": "False only when the task clearly is not work for this repository."],
                        "reason": ["type": "string", "description": "When include is false: why, in at most five words, in the meeting's language. Else empty."],
                        "labels": ["type": "array", "items": ["type": "string"], "description": "At most two names from the given labels, exactly as written. Empty when none fits clearly."],
                        "context": ["type": "string", "description": "One or two sentences: what the task is about and why, from the meeting. In the meeting's language."],
                        "quote": ["type": "string", "description": "The one sentence from the transcript that best shows the task, word for word, or empty."],
                        "quoteSpeaker": ["type": "string"],
                        "quoteTime": ["type": "string", "description": "The timestamp of the quoted line as in the transcript (\"02:41\")."],
                        "due": ["type": "string", "description": "The due date as a full date in the meeting's language (\"Mittwoch, 8. Oktober\"), worked out from the meeting date, or empty."],
                    ],
                    "required": ["index", "include", "reason", "labels", "context", "quote", "quoteSpeaker", "quoteTime", "due"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["tasks"],
        "additionalProperties": false,
    ]

    static let system = """
    You turn the tasks of a meeting into GitHub issues for one repository. For each task, decide whether it is \
    work for that repository at all (organisational tasks such as interviews, invitations or purchases usually are \
    not), pick fitting labels only from the list you get (none rather than a poor fit, never invent one), and write \
    one or two factual sentences of context from what was said. Quote the sentence of the transcript that shows the \
    task best, exactly as written. Work out the due date from the meeting date when the meeting set one ("bis \
    Mittwoch" in a meeting on Tuesday 6 October is Wednesday 7 October). Write in the meeting's language. No \
    assumptions, no advice. Answer with a single JSON object that follows the schema, and nothing else.
    """

    public static func prompt(_ detail: MeetingDetail, tasks: [ActionItem], target: GitHubTarget, labels: [GitHubLabel], myName: String, budget: Int) -> String {
        let taskLines = tasks.enumerated().map { index, task in
            var line = "\(index). \(task.text)"
            if let owner = task.owner { line += " — Zuständig: \(owner)" }
            if let due = task.due { line += " — Fällig: \(due)" }
            return line
        }.joined(separator: "\n")
        let labelLines = labels.isEmpty ? "(keine)" : labels.map { $0.descr.isEmpty ? "- \($0.name)" : "- \($0.name): \($0.descr)" }.joined(separator: "\n")
        var transcript = Summarizer.transcriptText(detail, myName: myName)
        if transcript.count > budget { transcript = String(transcript.prefix(budget)) + "\n[…]" }
        return """
        \(Summarizer.header(detail))
        Repository: \(target.repo)\(target.projectTitle.map { " (Projekt „\($0)“)" } ?? "")

        Aufgaben:
        \(taskLines)

        Labels im Repository:
        \(labelLines)

        Transkript:
        \(transcript)
        """
    }

    public static func suggest(_ detail: MeetingDetail, tasks: [ActionItem], target: GitHubTarget, labels: [GitHubLabel], myName: String, provider: LLMProvider, model: String) async throws -> [IssueSuggestion] {
        let budget = max(provider.contextCharacters - 8_000, 6_000)
        let request = LLMRequest(system: system, prompt: prompt(detail, tasks: tasks, target: target, labels: labels, myName: myName, budget: budget), schema: schema, maxOutputTokens: 6_000)
        let text = try await provider.complete(request, model: model)
        return try parse(text, labels: labels, count: tasks.count)
    }

    static func parse(_ text: String, labels: [GitHubLabel], count: Int) throws -> [IssueSuggestion] {
        let json = try JSONExtraction.object(from: text)
        let known = Dictionary(labels.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        func string(_ value: JSONValue?) -> String {
            let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ["null", "none", "-", "n/a"].contains(text.lowercased()) ? "" : text
        }
        var result: [IssueSuggestion] = []
        for (position, item) in (json["tasks"]?.array ?? []).enumerated() {
            let index = item["index"]?.intValue ?? position
            guard (0..<count).contains(index), !result.contains(where: { $0.index == index }) else { continue }
            // Only labels the repository has, at most two; the model may vary the case.
            var names: [String] = []
            for name in item["labels"]?.array ?? [] {
                if let real = name.string.flatMap({ known[$0.lowercased()] }), !names.contains(real) { names.append(real) }
            }
            let include = item["include"]?.boolValue ?? true
            let reason = string(item["reason"])
            result.append(IssueSuggestion(
                index: index,
                include: include,
                reason: include || reason.isEmpty ? nil : reason,
                labels: Array(names.prefix(2)),
                context: string(item["context"]),
                quote: string(item["quote"]).trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”")),
                quoteSpeaker: string(item["quoteSpeaker"]),
                quoteTime: string(item["quoteTime"]),
                due: string(item["due"])
            ))
        }
        return result
    }

    /// The issue's description. Without `withContext` (switched off, or a public repository) only the due date goes in.
    public static func body(suggestion: IssueSuggestion?, task: ActionItem, detail: MeetingDetail, withContext: Bool) -> String {
        var parts: [String] = []
        if withContext, let suggestion {
            if !suggestion.context.isEmpty { parts.append(suggestion.context) }
            if !suggestion.quote.isEmpty {
                var quote = "> „\(suggestion.quote)“"
                let source = [suggestion.quoteSpeaker, suggestion.quoteTime].filter { !$0.isEmpty }.joined(separator: ", ")
                if !source.isEmpty { quote += "\n> — \(source)" }
                parts.append(quote)
            }
        }
        let due = (suggestion?.due.isEmpty == false ? suggestion?.due : nil) ?? task.due
        if let due, !due.isEmpty { parts.append(String(localized: "**Fällig:** \(due)", comment: "GitHub issue description, Markdown: the due day the meeting set")) }
        if withContext {
            let day = detail.meeting.startedAt.formatted(Date.FormatStyle(locale: AppLocale.current).day().month(.wide).year())
            parts.append("<sub>" + String(localized: "Aus dem Meeting \(Strings.quote(detail.meeting.title)) am \(day)", comment: "GitHub issue description: which meeting the task came from, and its date") + "</sub>")
        }
        return parts.joined(separator: "\n\n")
    }
}

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let text): Int(text)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let text): ["true", "ja", "yes"].contains(text.lowercased())
        default: nil
        }
    }
}
