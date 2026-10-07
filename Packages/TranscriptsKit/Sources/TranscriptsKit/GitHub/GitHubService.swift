import Foundation

/// What the app needs from GitHub, so the demo mode and tests can stand in for it.
public protocol GitHubService: Sendable {
    func catalog() async throws -> GitHubCatalog
    func repoMeta(repoId: String) async throws -> (meta: GitHubRepoMeta, openIssues: [GitHubIssueRef])
    /// Creates the issue, adds it to the target's project and sets its status there.
    func create(_ issue: NewIssue) async throws -> CreatedIssue
    func issueStates(ids: [String]) async throws -> [GitHubIssueState]
    /// Closes or reopens an issue and moves it to the given status on its project.
    func setDone(_ done: Bool, issueId: String, status: (projectId: String, itemId: String, fieldId: String, optionId: String)?) async throws
}

/// The real GitHub, through its GraphQL API.
public final class LiveGitHubService: GitHubService {
    let api: GitHubAPI
    let tokens: GitHubTokenStore

    public init(tokens: GitHubTokenStore, session: URLSession? = nil) {
        self.tokens = tokens
        self.api = GitHubAPI(client: GraphQLClient(tokenSource: tokens, session: session))
    }

    public func catalog() async throws -> GitHubCatalog {
        try await retryingAuth { try await self.api.catalog() }
    }

    public func repoMeta(repoId: String) async throws -> (meta: GitHubRepoMeta, openIssues: [GitHubIssueRef]) {
        try await retryingAuth { try await self.api.repoMeta(repoId: repoId) }
    }

    public func create(_ issue: NewIssue) async throws -> CreatedIssue {
        let made = try await api.createIssue(
            repoId: issue.target.repoId, title: issue.title, body: issue.body,
            assigneeIds: issue.assigneeIds, labelIds: issue.labelIds
        )
        var result = CreatedIssue(id: made.id, number: made.number, url: made.url)
        // The issue exists from here on: a failure below must not lose it.
        if let projectId = issue.target.projectId {
            do {
                let itemId = try await api.addToProject(projectId: projectId, contentId: made.id)
                result.projectItemId = itemId
                if let fieldId = issue.statusFieldId, let optionId = issue.statusOptionId {
                    try await api.setStatus(projectId: projectId, itemId: itemId, fieldId: fieldId, optionId: optionId)
                }
            } catch {
                result.projectError = error.localizedDescription
            }
        }
        return result
    }

    public func issueStates(ids: [String]) async throws -> [GitHubIssueState] {
        try await retryingAuth { try await self.api.issueStates(ids: ids) }
    }

    public func setDone(_ done: Bool, issueId: String, status: (projectId: String, itemId: String, fieldId: String, optionId: String)?) async throws {
        if done {
            try await api.closeIssue(id: issueId)
        } else {
            try await api.reopenIssue(id: issueId)
        }
        if let status {
            try await api.setStatus(projectId: status.projectId, itemId: status.itemId, fieldId: status.fieldId, optionId: status.optionId)
        }
    }

    /// A rejected token may just be stale (the CLI login was renewed): read it again once.
    private func retryingAuth<T>(_ work: @escaping () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch GitHubError.unauthorized {
            await tokens.invalidate()
            return try await work()
        }
    }
}

/// A made-up GitHub for the demo mode and the screenshots, matching the sample meetings.
public actor DemoGitHubService: GitHubService {
    private var nextNumber = 142
    private var issues: [String: GitHubIssueState] = [:]
    nonisolated let delay: Duration

    public init(delay: Duration = .milliseconds(350)) {
        self.delay = delay
    }

    static let viewer = GitHubUser(id: "U-lukas", login: "lukaskaibel", name: "Lukas Kaibel")

    static let webApp = GitHubRepository(id: "R-web", nameWithOwner: "acme/web-app", isPrivate: true)
    static let pdf = GitHubRepository(id: "R-pdf", nameWithOwner: "acme/pdf-renderer", isPrivate: true)
    static let website = GitHubRepository(id: "R-site", nameWithOwner: "acme/website", isPrivate: false)
    static let people = GitHubRepository(id: "R-people", nameWithOwner: "acme/people-ops", isPrivate: true)
    static let support = GitHubRepository(id: "R-support", nameWithOwner: "acme/support", isPrivate: true)
    static let transcripts = GitHubRepository(id: "R-transcripts", nameWithOwner: "lukaskaibel/transcripts-app", isPrivate: true)
    static let issuesApp = GitHubRepository(id: "R-issues", nameWithOwner: "lukaskaibel/issues-for-github", isPrivate: false)

    static let webProject = GitHubProject(
        id: "P-web", title: "Web-App", url: "https://github.com/orgs/acme/projects/1", statusFieldId: "F-web-status",
        statusOptions: [
            GitHubStatusOption(id: "S-backlog", name: "Backlog", color: "GRAY"),
            GitHubStatusOption(id: "S-todo", name: "Todo", color: "GRAY"),
            GitHubStatusOption(id: "S-progress", name: "In Progress", color: "YELLOW"),
            GitHubStatusOption(id: "S-review", name: "In Review", color: "GREEN"),
            GitHubStatusOption(id: "S-done", name: "Done", color: "PURPLE"),
        ],
        repositories: [webApp, pdf]
    )

    static var catalogValue: GitHubCatalog {
        let simple = [
            GitHubStatusOption(id: "S2-todo", name: "Todo", color: "GRAY"),
            GitHubStatusOption(id: "S2-progress", name: "In Progress", color: "YELLOW"),
            GitHubStatusOption(id: "S2-done", name: "Done", color: "PURPLE"),
        ]
        return GitHubCatalog(
            viewer: viewer,
            projects: [
                webProject,
                GitHubProject(id: "P-site", title: "Website", url: "https://github.com/orgs/acme/projects/2", statusFieldId: "F-site-status", statusOptions: simple, repositories: [website]),
                GitHubProject(id: "P-hiring", title: "Hiring", url: "https://github.com/orgs/acme/projects/3", statusFieldId: "F-hiring-status", statusOptions: simple, repositories: [people]),
                GitHubProject(id: "P-support", title: "Support", url: "https://github.com/orgs/acme/projects/4", statusFieldId: "F-support-status", statusOptions: simple, repositories: [support]),
            ],
            repositories: [webApp, pdf, transcripts, issuesApp, website, people, support]
        )
    }

    static let labels = [
        GitHubLabel(id: "L-bug", name: "bug", color: "d73a4a", descr: "Something isn't working"),
        GitHubLabel(id: "L-design", name: "design", color: "c45fa6"),
        GitHubLabel(id: "L-docs", name: "docs", color: "5f636b", descr: "Documentation"),
        GitHubLabel(id: "L-enhancement", name: "enhancement", color: "2f86b5", descr: "New feature or request"),
        GitHubLabel(id: "L-onboarding", name: "onboarding", color: "2f9b67"),
        GitHubLabel(id: "L-pdf", name: "pdf-export", color: "8b5cf6"),
        GitHubLabel(id: "L-qa", name: "qa", color: "d29a0a", descr: "Testing and quality"),
    ]

    static let users = [
        viewer,
        GitHubUser(id: "U-anna", login: "annaberger", name: "Anna Berger"),
        GitHubUser(id: "U-jonas", login: "jonas-weber", name: "Jonas Weber"),
        GitHubUser(id: "U-jonas2", login: "jweber-acme", name: "J. Weber"),
        GitHubUser(id: "U-miriam", login: "mokafor", name: "Miriam Okafor"),
        GitHubUser(id: "U-thomas", login: "tklein", name: "Thomas Klein"),
        GitHubUser(id: "U-max", login: "mreiter", name: "Max Reiter"),
        GitHubUser(id: "U-paula", login: "pschulz", name: "Paula Schulz"),
    ]

    static var openIssues: [GitHubIssueRef] {
        let german = AppLanguage.current == .german
        return [
        GitHubIssueRef(id: "I-131", number: 131, title: german ? "QA-Plan für Release 2.4" : "QA plan for release 2.4", url: "https://github.com/acme/web-app/issues/131", repo: "acme/web-app",
                       statuses: ["P-web": "In Progress"], projectItems: ["P-web": "PI-131"]),
        GitHubIssueRef(id: "I-128", number: 128, title: german ? "Excel-Export für Berichte prüfen" : "Check Excel export for reports", url: "https://github.com/acme/web-app/issues/128", repo: "acme/web-app",
                       statuses: ["P-web": "Backlog"], projectItems: ["P-web": "PI-128"]),
        GitHubIssueRef(id: "I-120", number: 120, title: german ? "Dark Mode in den Einstellungen" : "Dark mode in settings", url: "https://github.com/acme/web-app/issues/120", repo: "acme/web-app",
                       statuses: ["P-web": "Todo"], projectItems: ["P-web": "PI-120"]),
        ]
    }

    public func catalog() async throws -> GitHubCatalog {
        try await Task.sleep(for: delay)
        return Self.catalogValue
    }

    public func repoMeta(repoId: String) async throws -> (meta: GitHubRepoMeta, openIssues: [GitHubIssueRef]) {
        try await Task.sleep(for: delay)
        let labels = repoId == Self.webApp.id || repoId == Self.pdf.id ? Self.labels : Array(Self.labels.prefix(4))
        return (GitHubRepoMeta(labels: labels, assignableUsers: Self.users), repoId == Self.webApp.id ? Self.openIssues : [])
    }

    public func create(_ issue: NewIssue) async throws -> CreatedIssue {
        try await Task.sleep(for: delay)
        let number = nextNumber
        nextNumber += 1
        let id = "I-\(number)"
        var statuses: [String: String] = [:]
        if let projectId = issue.target.projectId, let optionId = issue.statusOptionId,
           let name = Self.catalogValue.project(projectId)?.statusOptions.first(where: { $0.id == optionId })?.name {
            statuses[projectId] = name
        }
        issues[id] = GitHubIssueState(id: id, title: issue.title, state: "OPEN", statuses: statuses, projectItems: issue.target.projectId.map { [$0: "PI-\(number)"] } ?? [:])
        return CreatedIssue(id: id, number: number, url: "https://github.com/\(issue.target.repo)/issues/\(number)", projectItemId: issue.target.projectId == nil ? nil : "PI-\(number)")
    }

    public func issueStates(ids: [String]) async throws -> [GitHubIssueState] {
        try await Task.sleep(for: delay)
        return ids.compactMap { id in
            if let known = issues[id] { return known }
            if let ref = Self.openIssues.first(where: { $0.id == id }) {
                return GitHubIssueState(id: id, title: ref.title, state: ref.state, statuses: ref.statuses, projectItems: ref.projectItems)
            }
            return nil
        }
    }

    public func setDone(_ done: Bool, issueId: String, status: (projectId: String, itemId: String, fieldId: String, optionId: String)?) async throws {
        try await Task.sleep(for: delay)
        var state = issues[issueId] ?? GitHubIssueState(id: issueId, title: "", state: "OPEN")
        state.state = done ? "CLOSED" : "OPEN"
        if let status, let name = Self.catalogValue.project(status.projectId)?.statusOptions.first(where: { $0.id == status.optionId })?.name {
            state.statuses[status.projectId] = name
        }
        issues[issueId] = state
    }

    /// For the demo: an issue closed on "GitHub", to show the task being checked off by itself.
    public func close(_ issueId: String) {
        issues[issueId]?.state = "CLOSED"
        if let project = issues[issueId]?.statuses.keys.first { issues[issueId]?.statuses[project] = "Done" }
    }
}
