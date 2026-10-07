import Foundation
import GRDB

/// A task that is on GitHub, with the meeting it came from.
public struct LinkedTask: Equatable, Sendable {
    public var item: ActionItem
    public var meetingTitle: String
    public var meetingDate: Date
}

extension AppDatabase {
    // MARK: Issues of tasks

    public func setIssue(_ issue: LinkedIssue?, of itemId: Int64, done: Bool? = nil) throws {
        try writer.write { db in
            guard var item = try ActionItem.fetchOne(db, key: itemId) else { return }
            item.issue = issue
            if let done { item.done = done }
            try item.update(db)
        }
    }

    /// Every task linked to an issue, newest meetings first.
    public func linkedTasks() throws -> [LinkedTask] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT actionItem.*, meeting.title AS meetingTitle, meeting.startedAt AS meetingDate
                FROM actionItem JOIN meeting ON meeting.id = actionItem.meetingId
                WHERE actionItem.issue IS NOT NULL
                ORDER BY meeting.startedAt DESC
                """)
            return try rows.map { row in
                LinkedTask(item: try ActionItem(row: row), meetingTitle: row["meetingTitle"], meetingDate: row["meetingDate"])
            }
        }
    }

    // MARK: Remembered targets

    static func fetchRoutes(_ db: Database) throws -> [GitHubRoute] {
        try GitHubRoute.order(Column("lastUsedAt").desc).fetchAll(db)
    }

    public func routes() throws -> [GitHubRoute] {
        try reader.read { db in try Self.fetchRoutes(db) }
    }

    /// Remembers that a meeting's tasks went to `target`: for its series, its title and its people.
    public func recordRoutes(_ keys: MeetingRouteKeys, target: GitHubTarget, at date: Date = Date()) throws {
        try writer.write { db in
            var entries: [(GitHubRoute.Kind, String, String, [String])] = []
            if let series = keys.series { entries.append((.series, series, keys.titleLabel, [])) }
            if let title = keys.title { entries.append((.title, title, keys.titleLabel, [])) }
            if !keys.people.isEmpty { entries.append((.people, keys.people.joined(separator: ","), keys.peopleLabel, keys.people)) }
            for (kind, key, label, members) in entries {
                if var existing = try GitHubRoute
                    .filter(Column("kind") == kind.rawValue && Column("key") == key && Column("targetKey") == target.key)
                    .fetchOne(db) {
                    existing.count += 1
                    existing.lastUsedAt = date
                    existing.label = label
                    existing.target = target
                    try existing.update(db)
                } else {
                    var route = GitHubRoute(kind: kind, key: key, label: label, members: members, target: target, lastUsedAt: date)
                    try route.insert(db)
                }
            }
        }
    }

    public func deleteRoute(_ id: Int64) throws {
        _ = try writer.write { db in try GitHubRoute.deleteOne(db, key: id) }
    }

    // MARK: People on GitHub

    public func setGitHub(_ user: GitHubUser?, of personId: String) throws {
        try writer.write { db in
            guard var person = try Person.fetchOne(db, key: personId) else { return }
            person.github = user
            try person.update(db)
        }
    }
}
