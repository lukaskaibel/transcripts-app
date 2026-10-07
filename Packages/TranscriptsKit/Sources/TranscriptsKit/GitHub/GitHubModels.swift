import Foundation

// MARK: - What GitHub knows

/// Someone on GitHub: the signed-in user or a person issues can be assigned to.
public struct GitHubUser: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var login: String
    public var name: String?
    public var avatarUrl: String?

    public init(id: String, login: String, name: String? = nil, avatarUrl: String? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarUrl = avatarUrl
    }
}

public struct GitHubLabel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Hex without "#", as GitHub stores it.
    public var color: String
    public var descr: String

    public init(id: String, name: String, color: String, descr: String = "") {
        self.id = id
        self.name = name
        self.color = color
        self.descr = descr
    }
}

/// One option of a project's Status field.
public struct GitHubStatusOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// GitHub's colour enum: GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE.
    public var color: String

    public init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }

    public var category: StatusCategory { StatusCategory.infer(from: name) }
}

public struct GitHubRepository: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var nameWithOwner: String
    public var isPrivate: Bool

    public init(id: String, nameWithOwner: String, isPrivate: Bool) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.isPrivate = isPrivate
    }

    public var shortName: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
    public var url: URL? { URL(string: "https://github.com/\(nameWithOwner)") }
}

/// A GitHub project (Projects v2): it has the statuses; its issues live in repositories.
public struct GitHubProject: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var statusFieldId: String?
    public var statusOptions: [GitHubStatusOption]
    /// The repositories linked to the project, where its new issues can go.
    public var repositories: [GitHubRepository]

    public init(id: String, title: String, url: String, statusFieldId: String?, statusOptions: [GitHubStatusOption], repositories: [GitHubRepository]) {
        self.id = id
        self.title = title
        self.url = url
        self.statusFieldId = statusFieldId
        self.statusOptions = statusOptions
        self.repositories = repositories
    }

    /// Where new issues start: the first not-yet-started status, else the backlog, else the first one.
    public var defaultStatus: GitHubStatusOption? {
        statusOptions.first { $0.category == .unstarted } ?? statusOptions.first { $0.category == .backlog } ?? statusOptions.first
    }

    public var doneStatus: GitHubStatusOption? {
        statusOptions.first { $0.category == .completed }
    }
}

/// Everything that can receive issues: the user's projects and the repositories they can write to.
public struct GitHubCatalog: Codable, Hashable, Sendable {
    public var viewer: GitHubUser
    public var projects: [GitHubProject]
    /// Repositories with issues turned on, most recently used first.
    public var repositories: [GitHubRepository]

    public init(viewer: GitHubUser, projects: [GitHubProject], repositories: [GitHubRepository]) {
        self.viewer = viewer
        self.projects = projects
        self.repositories = repositories
    }

    public func project(_ id: String?) -> GitHubProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Every place a task can go: each project with each of its repositories, then the repositories on their own.
    public var targets: [GitHubTarget] {
        var result: [GitHubTarget] = []
        var seen = Set<String>()
        for project in projects {
            for repo in project.repositories {
                let target = GitHubTarget(repository: repo, project: project)
                if seen.insert(target.key).inserted { result.append(target) }
            }
        }
        for repo in repositories {
            let target = GitHubTarget(repository: repo, project: nil)
            if seen.insert(target.key).inserted { result.append(target) }
        }
        return result
    }
}

/// Labels and people of one repository.
public struct GitHubRepoMeta: Codable, Hashable, Sendable {
    public var labels: [GitHubLabel]
    public var assignableUsers: [GitHubUser]

    public init(labels: [GitHubLabel], assignableUsers: [GitHubUser]) {
        self.labels = labels
        self.assignableUsers = assignableUsers
    }
}

/// Where a task becomes an issue: a repository, and the project it is added to (if any).
public struct GitHubTarget: Codable, Hashable, Identifiable, Sendable {
    public var repoId: String
    public var repo: String
    public var isPrivate: Bool
    public var projectId: String?
    public var projectTitle: String?

    public init(repoId: String, repo: String, isPrivate: Bool, projectId: String? = nil, projectTitle: String? = nil) {
        self.repoId = repoId
        self.repo = repo
        self.isPrivate = isPrivate
        self.projectId = projectId
        self.projectTitle = projectTitle
    }

    public init(repository: GitHubRepository, project: GitHubProject?) {
        self.init(repoId: repository.id, repo: repository.nameWithOwner, isPrivate: repository.isPrivate, projectId: project?.id, projectTitle: project?.title)
    }

    /// Stable identity: the same repository in another project is another target.
    public var key: String { "\(repoId)|\(projectId ?? "")" }
    public var id: String { key }

    /// "Web-App › acme/web-app", or the repository alone.
    public var title: String {
        if let projectTitle { return "\(projectTitle) › \(repo)" }
        return repo
    }
}

/// An issue a task is linked to, as last seen.
public struct LinkedIssue: Codable, Hashable, Sendable {
    public var id: String
    public var number: Int
    public var url: String
    public var title: String
    public var repo: String
    public var repoId: String
    public var projectId: String?
    public var projectItemId: String?
    /// The project status by name ("In Progress"), when the issue is on a project.
    public var status: String?
    /// "OPEN" or "CLOSED".
    public var state: String
    /// True for an issue that already existed and was only linked.
    public var linkedExisting: Bool
    public var linkedAt: Date
    public var checkedAt: Date?

    public init(id: String, number: Int, url: String, title: String, repo: String, repoId: String, projectId: String? = nil, projectItemId: String? = nil, status: String? = nil, state: String = "OPEN", linkedExisting: Bool = false, linkedAt: Date = Date(), checkedAt: Date? = nil) {
        self.id = id
        self.number = number
        self.url = url
        self.title = title
        self.repo = repo
        self.repoId = repoId
        self.projectId = projectId
        self.projectItemId = projectItemId
        self.status = status
        self.state = state
        self.linkedExisting = linkedExisting
        self.linkedAt = linkedAt
        self.checkedAt = checkedAt
    }

    public var isClosed: Bool { state != "OPEN" }
    /// "acme/web-app#142".
    public var reference: String { "\(repo)#\(number)" }
}

/// An existing issue found on GitHub, for linking instead of creating a duplicate.
public struct GitHubIssueRef: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var url: String
    public var repo: String
    public var state: String
    public var createdAt: Date?
    /// Its status per project it is on, by project id.
    public var statuses: [String: String]
    /// Its item per project it is on, by project id.
    public var projectItems: [String: String]

    public init(id: String, number: Int, title: String, url: String, repo: String, state: String = "OPEN", createdAt: Date? = nil, statuses: [String: String] = [:], projectItems: [String: String] = [:]) {
        self.id = id
        self.number = number
        self.title = title
        self.url = url
        self.repo = repo
        self.state = state
        self.createdAt = createdAt
        self.statuses = statuses
        self.projectItems = projectItems
    }
}

/// The current state of a linked issue, for keeping tasks in step.
public struct GitHubIssueState: Hashable, Sendable {
    public var id: String
    public var title: String
    public var state: String
    /// Status per project id.
    public var statuses: [String: String]
    public var projectItems: [String: String]

    public init(id: String, title: String, state: String, statuses: [String: String] = [:], projectItems: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.state = state
        self.statuses = statuses
        self.projectItems = projectItems
    }
}

/// What it takes to create one issue.
public struct NewIssue: Sendable {
    public var target: GitHubTarget
    public var title: String
    public var body: String
    public var assigneeIds: [String]
    public var labelIds: [String]
    public var statusFieldId: String?
    public var statusOptionId: String?

    public init(target: GitHubTarget, title: String, body: String, assigneeIds: [String] = [], labelIds: [String] = [], statusFieldId: String? = nil, statusOptionId: String? = nil) {
        self.target = target
        self.title = title
        self.body = body
        self.assigneeIds = assigneeIds
        self.labelIds = labelIds
        self.statusFieldId = statusFieldId
        self.statusOptionId = statusOptionId
    }
}

public struct CreatedIssue: Sendable, Hashable {
    public var id: String
    public var number: Int
    public var url: String
    public var projectItemId: String?
    /// Set when the issue was created but adding it to the project or setting its status did not work.
    public var projectError: String?
}

// MARK: - Status semantics

/// What a status means, inferred from its name, since GitHub only stores a free-form option.
/// Same rules as in Issues for GitHub, so both apps draw the same circle for a status.
public enum StatusCategory: Int, Sendable, Comparable {
    case backlog
    case unstarted
    case started
    case completed
    case canceled

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func infer(from name: String) -> StatusCategory {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("cancel", "won't", "wont", "not planned", "duplicate", "rejected", "dropped", "abandon", "verworfen", "abgebrochen") { return .canceled }
        if has("done", "complete", "closed", "shipped", "released", "merged", "finished", "resolved", "live", "erledigt", "fertig") { return .completed }
        if has("progress", "review", "doing", "wip", "testing", "blocked", "active", "arbeit") { return .started }
        if has("backlog", "icebox", "later", "someday", "triage", "inbox", "ideas", "no status", "später") { return .backlog }
        if has("todo", "to do", "to-do", "open", "up next", "next", "ready", "planned", "new", "not started", "queued", "offen", "geplant") { return .unstarted }
        return .started
    }

    public var isClosed: Bool { self == .completed || self == .canceled }
}
