import Foundation
import GRDB

/// Something the app remembered about where a meeting's tasks went: for a calendar series, a meeting title or a
/// group of people, this target, so many times.
public struct GitHubRoute: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "githubRoute"

    public enum Kind: String, Codable, Sendable {
        /// The same calendar event (all meetings of a recurring series share it).
        case series
        /// A meeting with the same title, numbers left out ("Sprint Planning 43" and "44").
        case title
        /// The same people talking.
        case people
    }

    public var id: Int64?
    public var kind: Kind
    public var key: String
    /// What the settings show: the meeting title or the people's names.
    public var label: String
    /// For `people`: the person ids.
    public var members: [String]
    public var target: GitHubTarget
    public var targetKey: String
    public var count: Int
    public var lastUsedAt: Date

    public init(id: Int64? = nil, kind: Kind, key: String, label: String, members: [String] = [], target: GitHubTarget, count: Int = 1, lastUsedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.key = key
        self.label = label
        self.members = members
        self.target = target
        self.targetKey = target.key
        self.count = count
        self.lastUsedAt = lastUsedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// What identifies a meeting for remembering targets.
public struct MeetingRouteKeys: Equatable, Sendable {
    public var series: String?
    public var title: String?
    public var titleLabel: String
    /// Person ids of the others in the meeting, sorted.
    public var people: [String]
    public var peopleLabel: String

    public init(series: String?, title: String?, titleLabel: String, people: [String], peopleLabel: String) {
        self.series = series
        self.title = title
        self.titleLabel = titleLabel
        self.people = people
        self.peopleLabel = peopleLabel
    }
}

/// A place the tasks of a meeting could go, with why the app thinks so.
public struct TargetSuggestion: Equatable, Sendable {
    public var target: GitHubTarget
    public var score: Double
    /// "Wie bei den letzten 3 Terminen dieser Serie".
    public var reason: String
    /// The same, short enough for the composer's header: "wie die letzten 3 Termine".
    public var short: String
    /// Remembered from this kind of meeting before (rather than only the last target used anywhere).
    public var isRemembered: Bool
}

/// Proposes where a meeting's tasks go, from the routes remembered for earlier meetings.
public enum TargetSuggester {
    public static func keys(for detail: MeetingDetail) -> MeetingRouteKeys {
        let meeting = detail.meeting
        // Only titles that say something: from the calendar or typed by the user, not "Aufnahme 14:03".
        let usefulTitle = meeting.calendarEventId != nil || meeting.titleIsCustom
        let title = usefulTitle ? normalizedTitle(meeting.title) : nil
        var people: [(id: String, name: String)] = []
        for speaker in detail.speakers where !speaker.isMe {
            guard let id = speaker.personId, let person = detail.people[id], !person.isMe, !people.contains(where: { $0.id == id }) else { continue }
            people.append((id, person.name))
        }
        people.sort { $0.id < $1.id }
        return MeetingRouteKeys(
            series: meeting.calendarEventId,
            title: title?.isEmpty == false ? title : nil,
            titleLabel: meeting.title,
            people: people.map(\.id),
            peopleLabel: names(people.map(\.name))
        )
    }

    /// "sprint planning" for "Sprint Planning 43", "pia architecture weekly sync" for "[PIA] - Architecture Weekly Sync".
    public static func normalizedTitle(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        let letters = folded.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// "Anna", "Anna und Thomas", "Anna, Thomas und Miriam" (first names, joined as the interface's language does).
    public static func names(_ full: [String]) -> String {
        let first = full.map { String($0.split(separator: " ").first ?? Substring($0)) }
        return first.formatted(.list(type: .and).locale(AppLocale.current))
    }

    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let left = Set(a), right = Set(b)
        guard !left.isEmpty || !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// The remembered targets for this meeting, best first.
    public static func rank(_ keys: MeetingRouteKeys, routes: [GitHubRoute], now: Date = Date()) -> [TargetSuggestion] {
        struct Score {
            var target: GitHubTarget
            var total: Double = 0
            var best: Double = -1
            var reason = ""
            var short = ""
        }
        var scores: [String: Score] = [:]
        func add(_ route: GitHubRoute, _ points: Double, _ reason: String, _ short: String) {
            let days = max(0, now.timeIntervalSince(route.lastUsedAt) / 86_400)
            let value = points * max(0.35, pow(0.5, days / 90))
            var entry = scores[route.targetKey] ?? Score(target: route.target)
            entry.total += value
            if value > entry.best {
                entry.best = value
                entry.reason = reason
                entry.short = short
            }
            // The newest copy of the target, in case the project was renamed.
            entry.target = route.target
            scores[route.targetKey] = entry
        }
        for route in routes {
            let times = min(route.count, 5)
            switch route.kind {
            case .series where route.key == keys.series:
                add(route, 100 + 10 * Double(times),
                    String(localized: "Wie bei den letzten \(route.count) Terminen dieser Serie", comment: "plural: why a GitHub target is proposed: the same calendar series sent its tasks there (one: Wie beim letzten Termin dieser Serie)"),
                    String(localized: "wie die letzten \(route.count) Termine", comment: "plural: short reason after a sparkle, lower case (one: wie beim letzten Termin)"))
            case .title where route.key == keys.title:
                add(route, 80 + 8 * Double(times), String(localized: "Wie bei \(Strings.quote(route.label))", comment: "why a GitHub target is proposed: a meeting with the same title"),
                    String(localized: "wie bei \(Strings.quote(route.label))", comment: "short reason after a sparkle, lower case: a meeting with the same title"))
            case .people:
                let overlap = jaccard(keys.people, route.members)
                guard overlap >= 0.5, !keys.people.isEmpty else { continue }
                let when = route.lastUsedAt.formatted(Date.FormatStyle(locale: AppLocale.current).day().month(.abbreviated))
                add(route, 60 * overlap + 5 * Double(times),
                    overlap == 1
                        ? String(localized: "Gleiche Runde: \(route.label) · zuletzt am \(when)", comment: "why a GitHub target is proposed: the same people; names, then a date")
                        : String(localized: "Ähnliche Runde: \(route.label) · zuletzt am \(when)", comment: "why a GitHub target is proposed: mostly the same people; names, then a date"),
                    String(localized: "mit \(route.label)", comment: "short reason after a sparkle, lower case: the same people, by first name"))
            default:
                continue
            }
        }
        var result = scores.values.map { TargetSuggestion(target: $0.target, score: $0.total, reason: $0.reason, short: $0.short, isRemembered: true) }
        result.sort { $0.score > $1.score }
        if result.isEmpty, let last = routes.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            result = [TargetSuggestion(target: last.target, score: 1, reason: String(localized: "Zuletzt benutzt"), short: String(localized: "zuletzt benutzt", comment: "short reason after a sparkle, lower case: the last GitHub target used"), isRemembered: false)]
        }
        return result
    }
}

/// Telling whether two task titles mean the same thing, and who someone is on GitHub.
public enum IssueMatching {
    private static let stopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "für", "fur",
        "mit", "von", "vom", "zum", "zur", "im", "in", "am", "an", "auf", "aus", "bei", "bis", "nach", "noch", "mal",
        "the", "a", "an", "and", "or", "for", "with", "of", "to", "in", "on", "at", "by",
    ]

    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        let parts = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { $0.count >= 2 && !stopwords.contains($0) }.map(stem))
    }

    /// Cuts common German and English endings, so "Formulars" and "Formular" count as one word.
    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for ending in ["ungen", "ung", "en", "er", "es", "e", "s", "n"] where word.hasSuffix(ending) && word.count - ending.count >= 4 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// 0…1: how much two titles share, weighted towards the shorter one.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = Double(left.intersection(right).count)
        let jaccard = shared / Double(left.union(right).count)
        let containment = shared / Double(min(left.count, right.count))
        return 0.5 * jaccard + 0.5 * containment
    }

    /// The open issue that is most likely the same task, if one is close enough.
    public static func duplicate(of title: String, among issues: [GitHubIssueRef], threshold: Double = 0.62) -> GitHubIssueRef? {
        let ranked = issues.map { ($0, similarity(title, $0.title)) }.max { $0.1 < $1.1 }
        guard let ranked, ranked.1 >= threshold else { return nil }
        return ranked.0
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether an account could be this person: a name in common, or a login that contains one of the names.
    public static func fits(_ user: GitHubUser, name: String) -> Bool {
        let tokens = Set(fold(name).split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 })
        let theirs = Set(fold(user.name ?? "").split { !$0.isLetter }.map(String.init))
        if !tokens.isDisjoint(with: theirs) { return true }
        let login = fold(user.login).filter(\.isLetter)
        return tokens.contains { login.contains($0) }
    }

    /// The GitHub account of a person, by their name, when exactly one account fits clearly.
    public static func user(named name: String, among users: [GitHubUser]) -> GitHubUser? {
        let tokens = fold(name).split { !$0.isLetter }.map(String.init).filter { !$0.isEmpty }
        guard let first = tokens.first else { return nil }
        let last = tokens.count > 1 ? tokens.last : nil
        func best(_ test: (GitHubUser) -> Bool) -> GitHubUser?? {
            let matches = users.filter(test)
            if matches.count == 1 { return .some(matches[0]) }
            if matches.count > 1 { return .some(nil) }
            return nil
        }
        // Same full name on GitHub.
        if let found = best({ user in user.name.map { fold($0) == tokens.joined(separator: " ") } ?? false }) { return found }
        if let last {
            // First and last name both in the GitHub name.
            if let found = best({ user in
                let parts = Set(fold(user.name ?? "").split { !$0.isLetter }.map(String.init))
                return parts.contains(first) && parts.contains(last)
            }) { return found }
            // A login made of the name: "thomasklein", "thomas-klein", "tklein", "kleint".
            let login: (GitHubUser) -> String = { fold($0.login).filter(\.isLetter) }
            if let found = best({ user in
                let l = login(user)
                return l == first + last || l == last + first || l == String(first.prefix(1)) + last || l == first + String(last.prefix(1))
            }) { return found }
        } else {
            // Only a first name ("Lukas"): the login or the GitHub first name, if unique.
            if let found = best({ user in
                let parts = fold(user.name ?? "").split { !$0.isLetter }.map(String.init)
                return parts.first == first || fold(user.login) == first
            }) { return found }
        }
        return nil
    }
}
