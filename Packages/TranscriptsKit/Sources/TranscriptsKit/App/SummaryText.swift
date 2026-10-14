import Foundation

/// A summary as text to paste somewhere else: all of it as Markdown, or one of its parts.
public enum SummaryText {
    /// "Tabellen-Rendering beheben (Lukas, Mi)"
    public static func task(_ item: ActionItem) -> String {
        let extra = [item.owner, item.due].compactMap { $0 }.joined(separator: ", ")
        return item.text + (extra.isEmpty ? "" : " (\(extra))")
    }

    /// A Markdown checklist; what is done is checked.
    public static func tasks(_ items: [ActionItem]) -> String {
        items.map { "- [\($0.done ? "x" : " ")] \(task($0))" }.joined(separator: "\n")
    }

    public static func bullets(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Each topic's title, its points under it; with a `level`, the titles are Markdown headings of that level.
    public static func topics(_ topics: [SummaryTopic], level: Int? = nil) -> String {
        topics.map { topic in
            let title = level.map { String(repeating: "#", count: $0) + " " + topic.title } ?? topic.title
            let gap = level == nil ? "\n" : "\n\n"
            return topic.points.isEmpty ? title : title + gap + bullets(topic.points)
        }.joined(separator: "\n\n")
    }

    /// The summary from its overview on, its parts under headings of `level`.
    public static func sections(_ summary: MeetingSummary, tasks items: [ActionItem], level: Int) -> String {
        let heading = { (title: String) in String(repeating: "#", count: level) + " " + title + "\n\n" }
        // In the order the meeting screen shows them: what came out of it first, the details last.
        var parts = [summary.overview]
        if !summary.decisions.isEmpty { parts.append(heading(String(localized: "Entscheidungen")) + bullets(summary.decisions)) }
        if !items.isEmpty { parts.append(heading(String(localized: "Aufgaben")) + tasks(items)) }
        if !summary.openQuestions.isEmpty { parts.append(heading(String(localized: "Offene Fragen")) + bullets(summary.openQuestions)) }
        if !summary.topics.isEmpty {
            parts.append(heading(String(localized: "Themen", comment: "the subjects a meeting went through, in its summary")) + topics(summary.topics, level: level + 1))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The whole summary under the meeting's title and date, ready to paste into a chat, a ticket or a note.
    public static func markdown(_ detail: MeetingDetail) -> String {
        guard let summary = detail.summary else { return "" }
        let date = TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)
        return "# \(detail.meeting.title)\n\(date)\n\n" + sections(summary, tasks: detail.actionItems, level: 2)
    }
}
