import Foundation
import Testing
@testable import TranscriptsKit

/// Answers GitHub's GraphQL endpoint from a closure that sees the query, so the API can be tested offline.
final class GitHubMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((String, [String: Any]) -> (Int, Any))?
    nonisolated(unsafe) static var queries: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let query = json["query"] as? String ?? ""
        Self.queries.append(query)
        let (status, answer) = Self.handler?(query, json["variables"] as? [String: Any] ?? [:]) ?? (500, [:])
        let data = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func service() -> LiveGitHubService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubMockProtocol.self]
        queries = []
        return LiveGitHubService(tokens: GitHubTokenStore(secrets: MemorySecretStore(["github": "ghp_test"]), method: .token), session: URLSession(configuration: configuration))
    }
}

@Suite(.serialized) struct GitHubAPITests {
    static func repo(_ id: String, _ name: String, isPrivate: Bool = true, archived: Bool = false) -> [String: Any] {
        ["id": id, "nameWithOwner": name, "isPrivate": isPrivate, "isArchived": archived, "hasIssuesEnabled": true]
    }

    @Test func catalogCollectsOpenProjectsWithTheRepositoriesTheirIssuesLiveIn() async throws {
        GitHubMockProtocol.handler = { _, _ in
            (200, ["data": ["viewer": [
                "id": "U1", "login": "lukaskaibel", "name": "Lukas Kaibel", "avatarUrl": NSNull(),
                "projectsV2": ["nodes": [
                    ["id": "P1", "title": "Sandbox", "url": "u", "closed": false,
                     "field": ["id": "F1", "options": [["id": "O1", "name": "Todo", "color": "GRAY"], ["id": "O2", "name": "Done", "color": "PURPLE"]]],
                     "repositories": ["nodes": []],
                     "items": ["nodes": [
                        ["content": ["repository": Self.repo("R1", "lukaskaibel/sandbox")]],
                        ["content": ["repository": Self.repo("R1", "lukaskaibel/sandbox")]],
                        ["content": ["repository": Self.repo("R2", "lukaskaibel/other")]],
                        ["content": [:]],
                     ]]],
                    ["id": "P2", "title": "Old", "url": "u", "closed": true, "field": NSNull(), "repositories": ["nodes": []], "items": ["nodes": []]],
                ]],
                "organizations": ["nodes": [["projectsV2": ["nodes": [
                    ["id": "P3", "title": "PIA", "url": "u", "closed": false, "field": NSNull(),
                     "repositories": ["nodes": [Self.repo("R3", "CIATA-io/pia")]], "items": ["nodes": []]],
                ]]], NSNull()]],
                "repositories": ["nodes": [Self.repo("R1", "lukaskaibel/sandbox"), Self.repo("R4", "lukaskaibel/archive", archived: true), Self.repo("R5", "lukaskaibel/public", isPrivate: false)]],
            ]]])
        }
        let catalog = try await GitHubMockProtocol.service().catalog()
        #expect(catalog.viewer.login == "lukaskaibel")
        #expect(catalog.projects.map(\.title) == ["Sandbox", "PIA"])
        // Repositories come from the issues on the project, most used first.
        #expect(catalog.projects[0].repositories.map(\.nameWithOwner) == ["lukaskaibel/sandbox", "lukaskaibel/other"])
        #expect(catalog.projects[0].defaultStatus?.name == "Todo")
        #expect(catalog.projects[0].doneStatus?.name == "Done")
        #expect(catalog.repositories.map(\.nameWithOwner) == ["lukaskaibel/sandbox", "lukaskaibel/public"])
        let targets = catalog.targets.map(\.title)
        #expect(targets == ["Sandbox › lukaskaibel/sandbox", "Sandbox › lukaskaibel/other", "PIA › CIATA-io/pia", "lukaskaibel/sandbox", "lukaskaibel/public"])
        let request = try #require(GitHubMockProtocol.queries.first)
        #expect(request.contains("projectsV2") && request.contains("field(name: \"Status\")"))
    }

    @Test func creatingAddsTheIssueToTheProjectAndSetsItsStatus() async throws {
        GitHubMockProtocol.handler = { query, variables in
            if query.contains("createIssue") {
                #expect(variables["title"] as? String == "PDF-Export reparieren")
                #expect(variables["labels"] as? [String] == ["L1"])
                #expect(variables["assignees"] as? [String] == ["U2"])
                return (200, ["data": ["createIssue": ["issue": ["id": "I9", "number": 9, "url": "https://github.com/a/b/issues/9"]]]])
            }
            if query.contains("addProjectV2ItemById") { return (200, ["data": ["addProjectV2ItemById": ["item": ["id": "PI9"]]]]) }
            if query.contains("updateProjectV2ItemFieldValue") {
                #expect(variables["o"] as? String == "O1")
                return (200, ["data": ["updateProjectV2ItemFieldValue": ["clientMutationId": NSNull()]]])
            }
            return (500, [:])
        }
        let target = GitHubTarget(repoId: "R1", repo: "a/b", isPrivate: true, projectId: "P1", projectTitle: "Sandbox")
        let created = try await GitHubMockProtocol.service().create(NewIssue(target: target, title: "PDF-Export reparieren", body: "", assigneeIds: ["U2"], labelIds: ["L1"], statusFieldId: "F1", statusOptionId: "O1"))
        #expect(created.number == 9)
        #expect(created.projectItemId == "PI9")
        #expect(created.projectError == nil)
        #expect(GitHubMockProtocol.queries.count == 3)
    }

    @Test func anIssueThatCouldNotJoinTheProjectIsStillReported() async throws {
        GitHubMockProtocol.handler = { query, _ in
            if query.contains("createIssue") { return (200, ["data": ["createIssue": ["issue": ["id": "I9", "number": 9, "url": "u"]]]]) }
            return (200, ["data": ["addProjectV2ItemById": NSNull()], "errors": [["message": "Resource not accessible", "type": "FORBIDDEN"]]])
        }
        let target = GitHubTarget(repoId: "R1", repo: "a/b", isPrivate: true, projectId: "P1", projectTitle: "Sandbox")
        let created = try await GitHubMockProtocol.service().create(NewIssue(target: target, title: "x", body: ""))
        #expect(created.number == 9)
        #expect(created.projectItemId == nil)
        #expect(created.projectError == "Resource not accessible")
    }

    @Test func repositoryMetaBringsLabelsPeopleAndOpenIssuesWithTheirStatus() async throws {
        GitHubMockProtocol.handler = { _, _ in
            (200, ["data": ["node": [
                "nameWithOwner": "a/b",
                "labels": ["nodes": [["id": "L1", "name": "bug", "color": "d73a4a", "description": "Kaputt"]]],
                "assignableUsers": ["nodes": [["id": "U2", "login": "mokafor", "name": "Miriam Okafor", "avatarUrl": "https://a"]]],
                "issues": ["nodes": [["id": "I1", "number": 131, "title": "QA-Plan", "url": "u", "state": "OPEN", "createdAt": "2026-10-01T10:00:00Z",
                                      "projectItems": ["nodes": [["id": "PI1", "project": ["id": "P1"], "fieldValueByName": ["name": "In Progress"]]]]]]],
            ]]])
        }
        let result = try await GitHubMockProtocol.service().repoMeta(repoId: "R1")
        #expect(result.meta.labels.first?.descr == "Kaputt")
        #expect(result.meta.assignableUsers.first?.login == "mokafor")
        #expect(result.openIssues.first?.statuses["P1"] == "In Progress")
        #expect(result.openIssues.first?.projectItems["P1"] == "PI1")
        #expect(result.openIssues.first?.repo == "a/b")
    }

    @Test func aRejectedTokenIsReadAgainOnce() async throws {
        var calls = 0
        GitHubMockProtocol.handler = { _, _ in
            calls += 1
            if calls == 1 { return (401, ["message": "Bad credentials"]) }
            return (200, ["data": ["nodes": [["id": "I1", "title": "t", "state": "CLOSED", "projectItems": ["nodes": []]]]]])
        }
        let states = try await GitHubMockProtocol.service().issueStates(ids: ["I1"])
        #expect(states.first?.state == "CLOSED")
        #expect(calls == 2)
    }
}

@Suite struct TargetSuggesterTests {
    let web = GitHubTarget(repoId: "R1", repo: "acme/web-app", isPrivate: true, projectId: "P1", projectTitle: "Web-App")
    let pdf = GitHubTarget(repoId: "R2", repo: "acme/pdf", isPrivate: true, projectId: "P1", projectTitle: "Web-App")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func titlesAreComparedWithoutNumbersAndPunctuation() {
        #expect(TargetSuggester.normalizedTitle("Sprint Planning 43") == TargetSuggester.normalizedTitle("Sprint Planning 44"))
        #expect(TargetSuggester.normalizedTitle("[PIA] - Architecture Weekly Sync") == "pia architecture weekly sync")
        #expect(TargetSuggester.normalizedTitle("Übergabe Ökostrom") == "ubergabe okostrom")
    }

    @Test func theSeriesWinsOverASimilarGroupOfPeople() {
        let keys = MeetingRouteKeys(series: "E1", title: "weekly", titleLabel: "Weekly", people: ["a", "b", "c"], peopleLabel: "Anna, Bert und Carl")
        let routes = [
            GitHubRoute(kind: .series, key: "E1", label: "Weekly", target: web, count: 3, lastUsedAt: now.addingTimeInterval(-7 * 86_400)),
            GitHubRoute(kind: .people, key: "a,b", label: "Anna und Bert", members: ["a", "b"], target: pdf, count: 5, lastUsedAt: now),
        ]
        let ranked = TargetSuggester.rank(keys, routes: routes, now: now)
        #expect(ranked.map(\.target) == [web, pdf])
        #expect(ranked[0].reason == "Wie bei den letzten 3 Terminen dieser Serie")
        #expect(ranked[0].short == "wie die letzten 3 Termine")
        #expect(ranked[1].reason.hasPrefix("Ähnliche Runde: Anna und Bert"))
    }

    @Test func aDifferentGroupOfPeopleSuggestsNothingButTheLastTarget() {
        let keys = MeetingRouteKeys(series: nil, title: nil, titleLabel: "Call", people: ["x", "y", "z"], peopleLabel: "")
        let routes = [GitHubRoute(kind: .people, key: "a,b", label: "Anna und Bert", members: ["a", "b"], target: pdf, lastUsedAt: now)]
        let ranked = TargetSuggester.rank(keys, routes: routes, now: now)
        #expect(ranked.count == 1)
        #expect(ranked[0].target == pdf)
        #expect(ranked[0].isRemembered == false)
        #expect(TargetSuggester.rank(keys, routes: [], now: now).isEmpty)
    }

    @Test func namesReadLikeASentence() {
        #expect(TargetSuggester.names(["Anna Berger"]) == "Anna")
        #expect(TargetSuggester.names(["Anna Berger", "Thomas Klein", "Miriam Okafor"]) == "Anna, Thomas und Miriam")
    }
}

@Suite struct IssueMatchingTests {
    let users = [
        GitHubUser(id: "1", login: "lukaskaibel", name: "Lukas Kaibel"),
        GitHubUser(id: "2", login: "mokafor", name: "Miriam Okafor"),
        GitHubUser(id: "3", login: "tklein"),
        GitHubUser(id: "4", login: "jonas-weber", name: "Jonas Weber"),
        GitHubUser(id: "5", login: "jweber-acme", name: "J. Weber"),
        GitHubUser(id: "6", login: "anna", name: "Anna Berger"),
        GitHubUser(id: "7", login: "annab", name: "Anna Bauer"),
    ]

    @Test func peopleAreFoundByTheirNameOnGitHubOrTheirLogin() {
        #expect(IssueMatching.user(named: "Miriam Okafor", among: users)?.login == "mokafor")
        #expect(IssueMatching.user(named: "Thomas Klein", among: users)?.login == "tklein")
        #expect(IssueMatching.user(named: "Jonas Weber", among: users)?.login == "jonas-weber")
        #expect(IssueMatching.user(named: "Lukas", among: users)?.login == "lukaskaibel")
    }

    @Test func aPickedAccountMustFitTheNameToBeRemembered() {
        #expect(IssueMatching.fits(users[1], name: "Miriam Okafor"))
        #expect(IssueMatching.fits(users[2], name: "Thomas Klein"))
        #expect(!IssueMatching.fits(users[2], name: "Miriam Okafor"))
    }

    @Test func twoAccountsThatFitEquallyAreLeftForTheUser() {
        #expect(IssueMatching.user(named: "Anna", among: users) == nil)
        #expect(IssueMatching.user(named: "Paula Schulz", among: users) == nil)
    }

    @Test func theSameTaskInOtherWordsCountsAsADuplicate() {
        let issues = [
            GitHubIssueRef(id: "a", number: 131, title: "QA-Plan für Release 2.4", url: "", repo: "r"),
            GitHubIssueRef(id: "b", number: 120, title: "Dark Mode in den Einstellungen", url: "", repo: "r"),
        ]
        #expect(IssueMatching.duplicate(of: "QA-Plan für Release 2.4", among: issues)?.number == 131)
        #expect(IssueMatching.duplicate(of: "QA-Plan für das Release 2.4 schreiben", among: issues)?.number == 131)
        #expect(IssueMatching.duplicate(of: "Release-Notes für 2.4", among: issues) == nil)
        #expect(IssueMatching.duplicate(of: "Tabellen-Rendering im PDF-Export beheben", among: issues) == nil)
    }
}

@Suite struct IssueDrafterTests {
    let labels = [GitHubLabel(id: "L1", name: "bug", color: "d73a4a"), GitHubLabel(id: "L2", name: "pdf-export", color: "8b5cf6"), GitHubLabel(id: "L3", name: "qa", color: "d29a0a")]

    @Test func onlyTheRepositorysOwnLabelsAreKeptAtMostTwo() throws {
        let answer = """
        {"tasks": [
          {"index": 0, "include": true, "reason": "", "labels": ["Bug", "pdf-export", "qa", "frontend"], "context": "Kontext.", "quote": "„Es liegt an den Tabellen.“", "quoteSpeaker": "Lukas", "quoteTime": "02:41", "due": ""},
          {"index": 1, "include": false, "reason": "Eher kein Repo-Thema", "labels": [], "context": "", "quote": "", "quoteSpeaker": "", "quoteTime": "", "due": ""},
          {"index": 7, "include": true, "reason": "", "labels": [], "context": "", "quote": "", "quoteSpeaker": "", "quoteTime": "", "due": ""}
        ]}
        """
        let suggestions = try IssueDrafter.parse(answer, labels: labels, count: 2)
        #expect(suggestions.count == 2)
        #expect(suggestions[0].labels == ["bug", "pdf-export"])
        #expect(suggestions[0].quote == "Es liegt an den Tabellen.")
        #expect(suggestions[1].include == false)
        #expect(suggestions[1].reason == "Eher kein Repo-Thema")
    }

    @Test func theDescriptionLeavesTheTranscriptOutWhenAsked() throws {
        let meeting = Meeting(id: "m", title: "Weekly", startedAt: Date(timeIntervalSince1970: 1_791_000_000), status: .ready)
        let detail = MeetingDetail(meeting: meeting, segments: [], speakers: [], people: [:], summary: nil, actionItems: [], markers: [])
        let task = ActionItem(meetingId: "m", text: "QA-Plan", due: "Do")
        let suggestion = IssueSuggestion(index: 0, context: "Puffer für QA.", quote: "Dann bleibt Puffer.", quoteSpeaker: "Thomas Klein", quoteTime: "03:12", due: "Donnerstag, 8. Oktober")
        let full = IssueDrafter.body(suggestion: suggestion, task: task, detail: detail, withContext: true)
        #expect(full.contains("Puffer für QA."))
        #expect(full.contains("> „Dann bleibt Puffer.“\n> — Thomas Klein, 03:12"))
        #expect(full.contains("**Fällig:** Donnerstag, 8. Oktober"))
        #expect(full.contains("Aus dem Meeting „Weekly“"))
        let bare = IssueDrafter.body(suggestion: suggestion, task: task, detail: detail, withContext: false)
        #expect(bare == "**Fällig:** Donnerstag, 8. Oktober")
        #expect(IssueDrafter.body(suggestion: nil, task: ActionItem(meetingId: "m", text: "x"), detail: detail, withContext: false).isEmpty)
    }
}

@Suite struct GitHubDatabaseTests {
    @Test func aNewSummaryKeepsTheIssuesOfItsTasks() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Meeting(id: "m", title: "Weekly", status: .ready))
        let summary = MeetingSummary(meetingId: "m", overview: "o", decisions: [], openQuestions: [], model: "m", provider: "p")
        try database.save(summary: summary, actionItems: [ActionItem(meetingId: "m", text: "QA-Plan für Release 2.4"), ActionItem(meetingId: "m", text: "Interviews führen")])
        let first = try #require(try database.detail(of: "m")?.actionItems)
        let issue = LinkedIssue(id: "I1", number: 131, url: "u", title: "QA-Plan", repo: "a/b", repoId: "R1")
        try database.setIssue(issue, of: try #require(first[0].id), done: true)
        let other = LinkedIssue(id: "I2", number: 7, url: "u", title: "Interviews", repo: "a/b", repoId: "R1")
        try database.setIssue(other, of: try #require(first[1].id))

        // Rewritten: the QA task again in other words, the interviews gone.
        try database.save(summary: summary, actionItems: [ActionItem(meetingId: "m", text: "Den QA-Plan für Release 2.4 schreiben"), ActionItem(meetingId: "m", text: "Kunden informieren")])
        let second = try #require(try database.detail(of: "m")?.actionItems)
        #expect(second.map(\.text) == ["Den QA-Plan für Release 2.4 schreiben", "Kunden informieren", "Interviews führen"])
        #expect(second[0].issue?.number == 131)
        #expect(second[0].done)
        #expect(second[1].issue == nil)
        #expect(second[2].issue?.number == 7)
    }

    @Test func routesCountHowOftenATargetWasUsed() throws {
        let database = try AppDatabase.inMemory()
        let target = GitHubTarget(repoId: "R1", repo: "a/b", isPrivate: true, projectId: "P1", projectTitle: "Web")
        let keys = MeetingRouteKeys(series: "E1", title: "weekly", titleLabel: "Weekly", people: ["a", "b"], peopleLabel: "Anna und Bert")
        try database.recordRoutes(keys, target: target)
        try database.recordRoutes(keys, target: target)
        let routes = try database.routes()
        #expect(routes.count == 3)
        #expect(routes.allSatisfy { $0.count == 2 })
        #expect(routes.first { $0.kind == .people }?.members == ["a", "b"])
        try database.deleteRoute(try #require(routes.first?.id))
        #expect(try database.routes().count == 2)
    }

    @Test func mergingPeopleKeepsTheirGitHubAccount() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "a", name: "Miriam", github: GitHubUser(id: "U2", login: "mokafor")))
        try database.save(Person(id: "b", name: "Miriam Okafor"))
        try database.mergePerson("a", into: "b")
        #expect(try database.people().first?.github?.login == "mokafor")
    }
}

/// The whole flow on the sample data: suggestion, drafts, creating, and keeping the tasks in step.
@MainActor
@Suite(.serialized) struct GitHubFlowTests {
    func makeModel() throws -> (AppModel, AppDatabase, DemoGitHubService) {
        let database = try AppDatabase.inMemory()
        DemoData.seed(database)
        let defaults = UserDefaults(suiteName: "TranscriptsGitHubTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.githubLogin = .token
        let github = DemoGitHubService(delay: .zero)
        let model = AppModel(database: database, settings: settings, secrets: MemorySecretStore(), isDemo: true, github: github)
        return (model, database, github)
    }

    func prepared(_ model: AppModel, only: Int64? = nil) async throws -> IssueComposer {
        await model.refreshGitHubCatalog()
        let detail = try #require(try model.database.detail(of: "m-sync"))
        let composer = model.makeComposer(for: detail, only: only)
        await model.prepare(composer)
        return composer
    }

    @Test func theWeeklyGoesWhereItsSeriesWentWithLabelsPeopleAndTheExistingQAIssue() async throws {
        let (model, _, _) = try makeModel()
        let composer = try await prepared(model)
        #expect(composer.target?.repo == "acme/web-app")
        #expect(composer.suggestion?.short == "wie die letzten 3 Termine")
        let drafts = composer.drafts
        #expect(drafts.count == 4)
        let labels = model.labels(for: composer.target)
        func names(_ draft: IssueDraft) -> [String] { draft.labelIds.compactMap { id in labels.first { $0.id == id }?.name } }
        #expect(names(drafts[0]) == ["bug", "pdf-export"])
        #expect(drafts[0].labelsAreSuggested)
        #expect(drafts[0].assignees.map(\.login) == ["lukaskaibel"])
        #expect(drafts[1].assignees.map(\.login) == ["mokafor"])
        #expect(model.statusOptions(for: composer.target).first { $0.id == drafts[0].statusId }?.name == "Todo")
        // Not work for the repository.
        #expect(drafts[2].include == false)
        #expect(drafts[2].note == "Eher kein Repo-Thema")
        // Already an issue there.
        #expect(drafts[3].linkedRef?.number == 131)
        #expect(model.statusOptions(for: composer.target).first { $0.id == drafts[3].statusId }?.name == "In Progress")
        #expect(composer.newCount == 2 && composer.linkCount == 1)
    }

    @Test func creatingLinksTheTasksAndRemembersTheTarget() async throws {
        let (model, database, _) = try makeModel()
        let composer = try await prepared(model)
        // Change one by hand: Thomas instead of Miriam for the onboarding draft.
        let thomas = try #require(model.assignableUsers(for: composer.target).first { $0.login == "tklein" })
        let miriam = try #require(composer.drafts[1].assignees.first)
        model.toggleAssignee(miriam, of: composer.drafts[1].itemId, in: composer)
        model.toggleAssignee(thomas, of: composer.drafts[1].itemId, in: composer)
        let ok = await model.createIssues(from: composer)
        #expect(ok)
        let items = try #require(try database.detail(of: "m-sync")?.actionItems)
        #expect(items[0].issue?.number == 142)
        #expect(items[0].issue?.status == "Todo")
        #expect(items[1].issue?.number == 143)
        #expect(items[2].issue == nil)
        #expect(items[3].issue?.number == 131)
        #expect(items[3].issue?.linkedExisting == true)
        #expect(composer.drafts.map(\.text) == ["Technische Interviews mit drei Kandidaten"])
        let series = try database.routes().first { $0.kind == .series }
        #expect(series?.count == 4)
        // Without the app's string catalog the texts are the bare German keys; the plural forms come from the catalog.
        #expect(model.toasts.last?.title == "2 Issues angelegt")
        #expect(model.toasts.last?.message.hasPrefix("Web-App › acme/web-app · 1 ") == true)
        // Miriam's task went to Thomas: that says nothing about Miriam's own account.
        #expect(try database.people().first { $0.name == "Miriam Okafor" }?.github == nil)
        #expect(try database.people().first(where: \.isMe)?.github?.login == "lukaskaibel")
    }

    @Test func aClosedIssueChecksOffItsTaskAndCheckingOffClosesTheIssue() async throws {
        let (model, database, github) = try makeModel()
        let composer = try await prepared(model)
        _ = await model.createIssues(from: composer)
        var items = try #require(try database.detail(of: "m-sync")?.actionItems)
        let first = try #require(items[0].issue)

        await github.close(first.id)
        await model.refreshLinkedIssues(of: "m-sync", force: true)
        items = try #require(try database.detail(of: "m-sync")?.actionItems)
        #expect(items[0].done)
        #expect(items[0].issue?.status == "Done")

        // Unchecking in the app reopens it on GitHub and moves it back to Todo.
        model.setLinkedDone(items[0], done: false)
        try await Task.sleep(for: .milliseconds(100))
        let state = try #require(try await github.issueStates(ids: [first.id]).first)
        #expect(state.state == "OPEN")
        #expect(state.statuses["P-web"] == "Todo")
        #expect(try database.detail(of: "m-sync")?.actionItems[0].done == false)
    }

    @Test func afterASummaryTheTasksAreOfferedAndCreatedFromTheNotification() async throws {
        let (model, database, _) = try makeModel()
        let offer = try #require(await model.prepareOffer(for: "m-sync"))
        #expect(offer.title == "„Weekly Produkt-Sync“ ist zusammengefasst")
        #expect(offer.body == "Web-App › acme/web-app: 3 Aufgaben bereit, 1 davon gibt es dort schon.")
        await model.createPreparedIssues("m-sync")
        let items = try #require(try database.detail(of: "m-sync")?.actionItems)
        #expect(items.compactMap(\.issue?.number) == [142, 143, 131])
        // Nothing left to offer.
        #expect(await model.prepareOffer(for: "m-sync") == nil)
    }

    @Test func aTaskOpenedOnItsOwnIsAlwaysIncluded() async throws {
        let (model, database, _) = try makeModel()
        let interviews = try #require(try database.detail(of: "m-sync")?.actionItems.first { $0.text.contains("Interviews") }?.id)
        let composer = try await prepared(model, only: interviews)
        #expect(composer.drafts.count == 1)
        #expect(composer.drafts[0].include)
        #expect(composer.newCount == 1 && composer.linkCount == 0)
    }

    @Test func anotherRepositoryClearsTheLabelsAndTheDuplicate() async throws {
        let (model, _, _) = try makeModel()
        let composer = try await prepared(model)
        let website = try #require(model.githubCatalog?.targets.first { $0.repo == "acme/website" })
        model.setTarget(website, in: composer)
        try await Task.sleep(for: .milliseconds(200))
        #expect(composer.target?.isPrivate == false)
        #expect(composer.drafts[3].isLink == false)
        #expect(model.statusOptions(for: composer.target).first { $0.id == composer.drafts[0].statusId }?.name == "Todo")
    }
}
