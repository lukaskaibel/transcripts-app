import Foundation

/// Everything Transcripts asks of GitHub, one method per round trip. The queries follow those of Issues for GitHub.
public final class GitHubAPI: Sendable {
    public let client: GraphQLClient

    public init(client: GraphQLClient) {
        self.client = client
    }

    // MARK: Reading

    /// The signed-in user, their open projects with statuses and repositories, and the repositories they work in.
    public func catalog() async throws -> GitHubCatalog {
        struct Response: Decodable {
            struct ViewerDTO: Decodable {
                var id: String
                var login: String
                var name: String?
                var avatarUrl: String?
                var projectsV2: Nodes<ProjectDTO>?
                var organizations: Nodes<OrgDTO>?
                var repositories: Nodes<RepoDTO>?
            }
            struct OrgDTO: Decodable {
                var projectsV2: Nodes<ProjectDTO>?
            }
            var viewer: ViewerDTO
        }
        let query = """
        query {
          viewer {
            id login name avatarUrl
            projectsV2(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...P } }
            organizations(first: 30) { nodes { projectsV2(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...P } } } }
            repositories(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) { nodes { ...R } }
          }
        }
        fragment P on ProjectV2 {
          id title url closed
          field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name color } } }
          repositories(first: 20) { nodes { ...R } }
          items(first: 100) { nodes { content { ... on Issue { repository { ...R } } ... on PullRequest { repository { ...R } } } } }
        }
        fragment R on Repository { id nameWithOwner isPrivate isArchived hasIssuesEnabled }
        """
        // Organisations that enforce SAML return errors for their part only; keep the rest.
        let response: Response = try await client.run(query, allowPartial: true)
        let v = response.viewer
        var projects: [GitHubProject] = []
        var seen = Set<String>()
        let all = (v.projectsV2?.items ?? []) + (v.organizations?.items ?? []).flatMap { $0.projectsV2?.items ?? [] }
        for dto in all where !dto.closed && seen.insert(dto.id).inserted {
            projects.append(dto.project)
        }
        let repos = (v.repositories?.items ?? []).filter(\.usable).map(\.repository)
        return GitHubCatalog(viewer: GitHubUser(id: v.id, login: v.login, name: v.name, avatarUrl: v.avatarUrl), projects: projects, repositories: repos)
    }

    /// Labels, assignable people and the open issues of a repository (to link instead of creating duplicates).
    public func repoMeta(repoId: String) async throws -> (meta: GitHubRepoMeta, openIssues: [GitHubIssueRef]) {
        struct Response: Decodable {
            struct Node: Decodable {
                var nameWithOwner: String?
                var labels: Nodes<LabelDTO>?
                var assignableUsers: Nodes<UserDTO>?
                var issues: Nodes<IssueDTO>?
            }
            var node: Node?
        }
        let query = """
        query($id: ID!) {
          node(id: $id) { ... on Repository {
            nameWithOwner
            labels(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { id name color description } }
            assignableUsers(first: 100) { nodes { id login name avatarUrl } }
            issues(first: 100, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...I } }
          } }
        }
        \(IssueDTO.fragment)
        """
        let response: Response = try await client.run(query, variables: ["id": repoId], allowPartial: true)
        guard let node = response.node else {
            throw GitHubError.graphql([GraphQLErrorItem(message: String(localized: "Repository nicht gefunden."), type: "NOT_FOUND")])
        }
        let meta = GitHubRepoMeta(
            labels: (node.labels?.items ?? []).map(\.label),
            assignableUsers: (node.assignableUsers?.items ?? []).map(\.user)
        )
        let repo = node.nameWithOwner ?? ""
        return (meta, (node.issues?.items ?? []).map { $0.ref(repo: repo) })
    }

    /// The current state of linked issues, with their status on each project they are on.
    public func issueStates(ids: [String]) async throws -> [GitHubIssueState] {
        struct Response: Decodable {
            var nodes: [IssueDTO?]
        }
        let query = """
        query($ids: [ID!]!) { nodes(ids: $ids) { ...I } }
        \(IssueDTO.fragment)
        """
        var result: [GitHubIssueState] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            // Deleted issues come back as null with an error; keep the others.
            let response: Response = try await client.run(query, variables: ["ids": chunk], allowPartial: true)
            result += response.nodes.compactMap { $0 }.compactMap(\.issueState)
        }
        return result
    }

    // MARK: Writing

    private struct Ack: Decodable {}

    public func createIssue(repoId: String, title: String, body: String, assigneeIds: [String], labelIds: [String]) async throws -> (id: String, number: Int, url: String) {
        struct Response: Decodable {
            struct Payload: Decodable {
                struct IssueRef: Decodable {
                    var id: String
                    var number: Int
                    var url: String
                }
                var issue: IssueRef?
            }
            var createIssue: Payload?
        }
        let query = """
        mutation($repo: ID!, $title: String!, $body: String, $assignees: [ID!], $labels: [ID!]) {
          createIssue(input: {repositoryId: $repo, title: $title, body: $body, assigneeIds: $assignees, labelIds: $labels}) {
            issue { id number url }
          }
        }
        """
        let response: Response = try await client.run(query, variables: [
            "repo": repoId, "title": title, "body": body, "assignees": assigneeIds, "labels": labelIds,
        ])
        guard let issue = response.createIssue?.issue else {
            throw GitHubError.decoding("createIssue lieferte kein Issue.")
        }
        return (issue.id, issue.number, issue.url)
    }

    /// Adds an issue to a project and returns the project item's id. Safe to repeat.
    public func addToProject(projectId: String, contentId: String) async throws -> String {
        struct Response: Decodable {
            struct Payload: Decodable {
                struct ItemRef: Decodable { var id: String }
                var item: ItemRef?
            }
            var addProjectV2ItemById: Payload?
        }
        let query = """
        mutation($p: ID!, $c: ID!) { addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } } }
        """
        let response: Response = try await client.run(query, variables: ["p": projectId, "c": contentId])
        guard let id = response.addProjectV2ItemById?.item?.id else {
            throw GitHubError.decoding("addProjectV2ItemById lieferte kein Element.")
        }
        return id
    }

    public func setStatus(projectId: String, itemId: String, fieldId: String, optionId: String) async throws {
        let query = """
        mutation($p: ID!, $i: ID!, $f: ID!, $o: String!) {
          updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { clientMutationId }
        }
        """
        let _: Ack = try await client.run(query, variables: ["p": projectId, "i": itemId, "f": fieldId, "o": optionId])
    }

    public func closeIssue(id: String, notPlanned: Bool = false) async throws {
        let query = """
        mutation($id: ID!, $r: IssueClosedStateReason) {
          closeIssue(input: {issueId: $id, stateReason: $r}) { clientMutationId }
        }
        """
        let _: Ack = try await client.run(query, variables: ["id": id, "r": notPlanned ? "NOT_PLANNED" : "COMPLETED"])
    }

    public func reopenIssue(id: String) async throws {
        let query = """
        mutation($id: ID!) { reopenIssue(input: {issueId: $id}) { clientMutationId } }
        """
        let _: Ack = try await client.run(query, variables: ["id": id])
    }
}

// MARK: - Response shapes

struct RepoDTO: Decodable {
    var id: String
    var nameWithOwner: String
    var isPrivate: Bool?
    var isArchived: Bool?
    var hasIssuesEnabled: Bool?

    var usable: Bool { isArchived != true && hasIssuesEnabled != false }
    var repository: GitHubRepository { GitHubRepository(id: id, nameWithOwner: nameWithOwner, isPrivate: isPrivate ?? true) }
}

struct ProjectDTO: Decodable {
    struct FieldDTO: Decodable {
        struct OptionDTO: Decodable {
            var id: String
            var name: String
            var color: String
        }
        var id: String?
        var options: [OptionDTO]?
    }
    var id: String
    var title: String
    var url: String
    var closed: Bool
    struct ItemDTO: Decodable {
        struct Content: Decodable { var repository: RepoDTO? }
        var content: Content?
    }
    var field: FieldDTO?
    var repositories: Nodes<RepoDTO>?
    var items: Nodes<ItemDTO>?

    /// The repositories linked to the project first, then those its items come from, most used first:
    /// many projects link none and simply collect issues from wherever they live.
    var repos: [GitHubRepository] {
        var result = (repositories?.items ?? []).filter(\.usable).map(\.repository)
        var counts: [String: (repo: GitHubRepository, count: Int)] = [:]
        for item in items?.items ?? [] {
            guard let dto = item.content?.repository, dto.usable else { continue }
            counts[dto.id, default: (dto.repository, 0)].count += 1
        }
        for entry in counts.values.sorted(by: { $0.count > $1.count }) where !result.contains(where: { $0.id == entry.repo.id }) {
            result.append(entry.repo)
        }
        return Array(result.prefix(10))
    }

    var project: GitHubProject {
        GitHubProject(
            id: id, title: title, url: url,
            statusFieldId: field?.id,
            statusOptions: (field?.options ?? []).map { GitHubStatusOption(id: $0.id, name: $0.name, color: $0.color) },
            repositories: repos
        )
    }
}

struct LabelDTO: Decodable {
    var id: String
    var name: String
    var color: String
    var description: String?
    var label: GitHubLabel { GitHubLabel(id: id, name: name, color: color, descr: description ?? "") }
}

struct UserDTO: Decodable {
    var id: String
    var login: String
    var name: String?
    var avatarUrl: String?
    var user: GitHubUser { GitHubUser(id: id, login: login, name: (name?.isEmpty == false) ? name : nil, avatarUrl: avatarUrl) }
}

struct IssueDTO: Decodable {
    struct ProjectItemDTO: Decodable {
        struct ProjectRef: Decodable { var id: String }
        struct StatusValue: Decodable { var name: String? }
        var id: String
        var project: ProjectRef?
        var fieldValueByName: StatusValue?
    }
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var state: String?
    var createdAt: Date?
    var projectItems: Nodes<ProjectItemDTO>?

    static let fragment = """
    fragment I on Issue {
      id number title url state createdAt
      projectItems(first: 10) { nodes { id project { id } fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
    }
    """

    var statuses: [String: String] {
        var result: [String: String] = [:]
        for item in projectItems?.items ?? [] {
            if let project = item.project?.id, let name = item.fieldValueByName?.name { result[project] = name }
        }
        return result
    }

    var items: [String: String] {
        var result: [String: String] = [:]
        for item in projectItems?.items ?? [] {
            if let project = item.project?.id { result[project] = item.id }
        }
        return result
    }

    func ref(repo: String) -> GitHubIssueRef {
        GitHubIssueRef(id: id ?? "", number: number ?? 0, title: title ?? "", url: url ?? "", repo: repo, state: state ?? "OPEN", createdAt: createdAt, statuses: statuses, projectItems: items)
    }

    var issueState: GitHubIssueState? {
        guard let id else { return nil }
        return GitHubIssueState(id: id, title: title ?? "", state: state ?? "OPEN", statuses: statuses, projectItems: items)
    }
}
