import AppKit
import Foundation

extension AppModel {
    // MARK: Connection

    public var isGitHubConnected: Bool { githubConnection.user != nil }
    public var githubViewer: GitHubUser? { githubCatalog?.viewer ?? githubConnection.user }

    /// Whether this Mac has a GitHub CLI to sign in with (as Issues for GitHub does).
    public var githubCLIAvailable: Bool { isDemo || GitHubCLI.isAvailable }
    public var githubDeviceFlowAvailable: Bool { !isDemo && GitHubDeviceFlow.configuredClientID != nil }

    /// Signs in with the token of the GitHub CLI.
    public func connectGitHubCLI() async {
        githubConnection = .connecting
        if !isDemo {
            do {
                _ = try await GitHubCLI.token()
            } catch {
                githubConnection = .failed(String(localized: "Die GitHub-CLI ist nicht angemeldet. Im Terminal „gh auth login“ ausführen und dann noch einmal versuchen."))
                return
            }
        }
        settings.githubLogin = .githubCLI
        await githubTokens.setMethod(.githubCLI)
        await refreshGitHubCatalog(force: true)
    }

    /// Signs in on github.com with a code: shows the code, opens the page, waits for the approval.
    public func startGitHubDeviceFlow() {
        guard let clientID = GitHubDeviceFlow.configuredClientID else { return }
        githubDeviceFlowTask?.cancel()
        githubConnection = .connecting
        let flow = GitHubDeviceFlow(clientID: clientID)
        githubDeviceFlowTask = Task {
            do {
                let code = try await flow.start()
                githubDeviceCode = code
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)
                let token = try await flow.waitForToken(code)
                githubDeviceCode = nil
                try secrets.setSecret(token, for: GitHubTokenStore.account)
                settings.githubLogin = .token
                await githubTokens.setMethod(.token)
                await refreshGitHubCatalog(force: true)
            } catch is CancellationError {
                githubDeviceCode = nil
            } catch {
                githubDeviceCode = nil
                githubConnection = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelGitHubDeviceFlow() {
        githubDeviceFlowTask?.cancel()
        githubDeviceFlowTask = nil
        githubDeviceCode = nil
        if case .connecting = githubConnection { githubConnection = .signedOut }
    }

    public func signOutGitHub() {
        cancelGitHubDeviceFlow()
        if settings.githubLogin == .token { try? secrets.setSecret(nil, for: GitHubTokenStore.account) }
        settings.githubLogin = nil
        Task { await githubTokens.setMethod(nil) }
        githubConnection = .signedOut
        githubCatalog = nil
        githubCatalogLoadedAt = nil
        githubRepoMeta = [:]
        githubOpenIssues = [:]
        githubMetaLoadedAt = [:]
        composer = nil
    }

    /// Loads the projects and repositories (again, if older than ten minutes or `force`d).
    public func refreshGitHubCatalog(force: Bool = false) async {
        guard settings.githubLogin != nil else { return }
        if let task = githubCatalogTask {
            await task.value
            if !force { return }
        }
        if !force, let loaded = githubCatalogLoadedAt, Date().timeIntervalSince(loaded) < 600, githubCatalog != nil { return }
        let task = Task { @MainActor in
            if githubCatalog == nil { githubConnection = .connecting }
            do {
                let catalog = try await github.catalog()
                githubCatalog = catalog
                githubCatalogLoadedAt = Date()
                githubConnection = .connected(catalog.viewer)
                linkMeToViewer(catalog.viewer)
            } catch {
                if githubCatalog == nil || (error as? GitHubError) == .unauthorized || (error as? GitHubError) == .noToken {
                    githubConnection = .failed(error.localizedDescription)
                }
            }
        }
        githubCatalogTask = task
        await task.value
        githubCatalogTask = nil
    }

    /// The user's own person is the signed-in GitHub account.
    private func linkMeToViewer(_ viewer: GitHubUser) {
        guard let me, me.github?.id != viewer.id else { return }
        try? database.setGitHub(viewer, of: me.id)
    }

    /// Labels, people and open issues of a repository, loaded once a minute at most.
    func ensureRepoMeta(_ repoId: String, force: Bool = false) async {
        if !force, githubRepoMeta[repoId] != nil, let loaded = githubMetaLoadedAt[repoId], Date().timeIntervalSince(loaded) < 60 { return }
        do {
            let result = try await github.repoMeta(repoId: repoId)
            githubRepoMeta[repoId] = result.meta
            githubOpenIssues[repoId] = result.openIssues
            githubMetaLoadedAt[repoId] = Date()
        } catch {
            if githubRepoMeta[repoId] == nil { composer?.error = error.localizedDescription }
        }
    }

    // MARK: Lookups

    public func githubProject(_ id: String?) -> GitHubProject? {
        githubCatalog?.project(id)
    }

    public func statusOptions(for target: GitHubTarget?) -> [GitHubStatusOption] {
        githubProject(target?.projectId)?.statusOptions ?? []
    }

    public func labels(for target: GitHubTarget?) -> [GitHubLabel] {
        target.flatMap { githubRepoMeta[$0.repoId]?.labels } ?? []
    }

    public func assignableUsers(for target: GitHubTarget?) -> [GitHubUser] {
        var users = target.flatMap { githubRepoMeta[$0.repoId]?.assignableUsers } ?? []
        if let viewer = githubViewer, !users.contains(where: { $0.id == viewer.id }) { users.insert(viewer, at: 0) }
        return users
    }

    /// Loads the people of the repositories tasks usually go to, so a person can be linked to their account.
    public func loadKnownGitHubAccounts() async {
        guard settings.githubLogin != nil else { return }
        await refreshGitHubCatalog()
        var repos: [String] = []
        for repo in githubRoutes.map(\.target.repoId) + (githubCatalog?.repositories.prefix(1).map(\.id) ?? []) where !repos.contains(repo) {
            repos.append(repo)
        }
        for repo in repos.prefix(3) where githubRepoMeta[repo] == nil { await ensureRepoMeta(repo) }
    }

    /// Every GitHub account known from any repository, for linking a person by hand.
    public var knownGitHubUsers: [GitHubUser] {
        var seen = Set<String>()
        var result: [GitHubUser] = []
        for user in ([githubViewer].compactMap { $0 } + githubRepoMeta.values.flatMap(\.assignableUsers) + people.compactMap(\.github)) where seen.insert(user.id).inserted {
            result.append(user)
        }
        return result.sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
    }

    /// The remembered places for a meeting's tasks, best first; only targets that still exist once the catalog is in.
    public func targetSuggestions(for detail: MeetingDetail) -> [TargetSuggestion] {
        var ranked = TargetSuggester.rank(TargetSuggester.keys(for: detail), routes: githubRoutes)
        if let catalog = githubCatalog {
            let current = Dictionary(catalog.targets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            ranked = ranked.compactMap { suggestion in
                guard let target = current[suggestion.target.key] else { return nil }
                var updated = suggestion
                updated.target = target
                return updated
            }
        }
        return ranked
    }

    /// Where the tasks of this meeting already went, if any of them did.
    func linkedTarget(of detail: MeetingDetail) -> GitHubTarget? {
        guard let issue = detail.actionItems.compactMap(\.issue).last else { return nil }
        return githubCatalog?.targets.first { $0.repoId == issue.repoId && $0.projectId == issue.projectId }
            ?? GitHubTarget(repoId: issue.repoId, repo: issue.repo, isPrivate: true, projectId: issue.projectId, projectTitle: githubProject(issue.projectId)?.title)
    }

    /// The person a task's owner names ("Miriam", "Lukas Kaibel"), among the meeting's people and everyone known.
    func persons(forOwner owner: String?, in detail: MeetingDetail) -> [Person] {
        guard let owner, !owner.isEmpty else { return [] }
        let names = owner
            .replacingOccurrences(of: " und ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: "/", with: ",")
            .split(separator: ",")
            .map { IssueMatching.fold(String($0)) }
            .filter { !$0.isEmpty }
        let candidates = Array(detail.people.values) + people.filter { detail.people[$0.id] == nil }
        var result: [Person] = []
        for name in names {
            let isMe = name == "ich" || name == "du" || (me.map { IssueMatching.fold($0.firstName) == name || IssueMatching.fold($0.name) == name } ?? false)
            let found = isMe ? me : (candidates.first { IssueMatching.fold($0.name) == name } ?? candidates.first { IssueMatching.fold($0.firstName) == name })
            if let found, !result.contains(where: { $0.id == found.id }) { result.append(found) }
        }
        return result
    }

    /// The GitHub account of a person among the repository's people: the one they are linked to, else by name.
    func githubUser(for person: Person, among users: [GitHubUser]) -> GitHubUser? {
        if person.isMe, let viewer = githubViewer { return viewer }
        if let linked = person.github {
            return users.first { $0.id == linked.id } ?? users.first { $0.login.caseInsensitiveCompare(linked.login) == .orderedSame }
        }
        return IssueMatching.user(named: person.name, among: users)
    }

    /// The accounts of the meeting's people (who spoke or was invited), for the top of the assignee picker.
    public func meetingUsers(for detail: MeetingDetail, among users: [GitHubUser]) -> [GitHubUser] {
        var result: [GitHubUser] = []
        func add(_ user: GitHubUser?) {
            if let user, !result.contains(where: { $0.id == user.id }) { result.append(user) }
        }
        add(githubViewer.flatMap { viewer in users.first { $0.id == viewer.id } })
        for speaker in detail.speakers {
            if let id = speaker.personId, let person = detail.people[id] { add(githubUser(for: person, among: users)) }
        }
        for attendee in detail.meeting.attendees {
            if let person = people.first(where: { IssueMatching.fold($0.name) == IssueMatching.fold(attendee.name) }) {
                add(githubUser(for: person, among: users))
            } else {
                add(IssueMatching.user(named: attendee.name, among: users))
            }
        }
        return result
    }

    // MARK: The composer

    /// Opens the composer for a meeting's open tasks (or one task), keeping one that is still open for the same.
    @discardableResult
    public func openComposer(meetingId: String, only itemId: Int64? = nil) -> IssueComposer? {
        let current = (detail?.meeting.id == meetingId ? detail : nil) ?? (try? database.detail(of: meetingId))
        let eligible = Set(current?.actionItems.filter { $0.issue == nil && (itemId == nil ? !$0.done : $0.id == itemId) }.compactMap(\.id) ?? [])
        // The one still open keeps what was changed in it, unless the tasks changed meanwhile.
        if let composer, composer.meetingId == meetingId, composer.only == itemId, !composer.creating,
           Set(composer.drafts.map(\.itemId)) == eligible {
            Task { await prepare(composer) }
            return composer
        }
        if itemId == nil, let prepared = preparedComposers.removeValue(forKey: meetingId) {
            composer = prepared
            Task { await prepare(prepared) }
            return prepared
        }
        guard let detail = (detail?.meeting.id == meetingId ? detail : nil) ?? (try? database.detail(of: meetingId)) else { return nil }
        let created = makeComposer(for: detail, only: itemId)
        guard !created.drafts.isEmpty else { return nil }
        composer = created
        Task { await prepare(created) }
        return created
    }

    func makeComposer(for detail: MeetingDetail, only itemId: Int64?) -> IssueComposer {
        let items = detail.actionItems.filter { item in
            item.issue == nil && (itemId == nil ? !item.done : item.id == itemId)
        }
        let composer = IssueComposer(meetingId: detail.meeting.id, only: itemId, drafts: items.map(IssueDraft.init), includeContext: settings.githubIncludeContext)
        if let suggestion = targetSuggestions(for: detail).first {
            composer.target = suggestion.target
            composer.suggestion = suggestion
        } else if let linked = linkedTarget(of: detail) {
            composer.target = linked
            composer.suggestion = TargetSuggestion(target: linked, score: 1, reason: String(localized: "Wie die anderen Aufgaben dieses Meetings"), short: String(localized: "wie die anderen Aufgaben", comment: "why a GitHub target is proposed, lower case after a sparkle"), isRemembered: true)
        }
        return composer
    }

    public func setTarget(_ target: GitHubTarget, in composer: IssueComposer) {
        guard composer.target?.key != target.key else { return }
        let labelsFollowRepo = composer.target?.repoId != target.repoId
        composer.target = target
        composer.suggestion = nil
        composer.error = nil
        for index in composer.drafts.indices {
            // Labels and people belong to a repository; statuses to a project.
            if labelsFollowRepo {
                composer.drafts[index].labelIds = []
                composer.drafts[index].suggestedLabelIds = []
                composer.drafts[index].touchedLabels = false
                composer.drafts[index].touchedAssignees = false
                if !composer.drafts[index].touchedMode {
                    composer.drafts[index].mode = .create
                    composer.drafts[index].duplicate = nil
                }
            }
            composer.drafts[index].touchedStatus = false
        }
        Task { await prepare(composer) }
    }

    /// Fills in what can be worked out: statuses, people, duplicates, then the model's labels and descriptions.
    func prepare(_ composer: IssueComposer) async {
        if githubCatalog == nil || composer.target == nil { await refreshGitHubCatalog() }
        if composer.target == nil, let detail = try? database.detail(of: composer.meetingId) {
            if let suggestion = targetSuggestions(for: detail).first {
                composer.target = suggestion.target
                composer.suggestion = suggestion
            } else if let linked = linkedTarget(of: detail) {
                composer.target = linked
            }
        }
        guard let target = composer.target else { return }
        composer.loadingMeta = githubRepoMeta[target.repoId] == nil
        await ensureRepoMeta(target.repoId)
        composer.loadingMeta = false
        guard composer.target?.key == target.key, let detail = try? database.detail(of: composer.meetingId) else { return }
        applyDefaults(to: composer, target: target, detail: detail)
        await draftWithModel(composer, target: target, detail: detail)
    }

    func applyDefaults(to composer: IssueComposer, target: GitHubTarget, detail: MeetingDetail) {
        let project = githubProject(target.projectId)
        let users = assignableUsers(for: target)
        let candidates = duplicateCandidates(for: target, excluding: detail)
        let fresh = composer.preparedTargetKey != target.key
        composer.preparedTargetKey = target.key
        for index in composer.drafts.indices {
            var draft = composer.drafts[index]
            if !draft.touchedMode, fresh || draft.duplicate == nil {
                let taken = Set(composer.drafts.compactMap { $0.linkedRef?.id })
                if let duplicate = IssueMatching.duplicate(of: draft.text, among: candidates.filter { !taken.contains($0.id) }) {
                    draft.duplicate = duplicate
                    draft.mode = .link(duplicate)
                }
            }
            if let ref = draft.linkedRef {
                // A linked issue shows the status it has on GitHub.
                let name = target.projectId.flatMap { ref.statuses[$0] }
                draft.statusId = project?.statusOptions.first { $0.name == name }?.id
            } else if !draft.touchedStatus || !(project?.statusOptions.contains { $0.id == draft.statusId } ?? false) {
                draft.statusId = project?.defaultStatus?.id
            }
            if !draft.touchedAssignees {
                draft.assignees = persons(forOwner: draft.owner, in: detail).compactMap { githubUser(for: $0, among: users) }
            }
            composer.drafts[index] = draft
        }
    }

    /// Open issues of the target's repository, and issues earlier meetings' tasks were linked to there.
    func duplicateCandidates(for target: GitHubTarget, excluding detail: MeetingDetail) -> [GitHubIssueRef] {
        var result = githubOpenIssues[target.repoId] ?? []
        let ownLinks = Set(detail.actionItems.compactMap { $0.issue?.id })
        if let linked = try? database.linkedTasks() {
            for task in linked {
                guard let issue = task.item.issue, issue.repoId == target.repoId, !issue.isClosed,
                      !result.contains(where: { $0.id == issue.id }) else { continue }
                var statuses: [String: String] = [:]
                var items: [String: String] = [:]
                if let project = issue.projectId {
                    statuses[project] = issue.status
                    items[project] = issue.projectItemId
                }
                result.append(GitHubIssueRef(id: issue.id, number: issue.number, title: issue.title, url: issue.url, repo: issue.repo, state: issue.state, statuses: statuses, projectItems: items))
            }
        }
        return result.filter { !ownLinks.contains($0.id) }
    }

    /// One request to the summary's model: labels, which tasks belong in the repository, and the descriptions.
    func draftWithModel(_ composer: IssueComposer, target: GitHubTarget, detail: MeetingDetail) async {
        let key = "\(composer.meetingId)|\(target.repoId)"
        let labels = labels(for: target)
        var suggestions = githubSuggestions[key]
        if suggestions == nil, settings.githubSuggestLabels, composer.draftedRepoId != target.repoId {
            let tasks = composer.drafts.compactMap { draft in detail.actionItems.first { $0.id == draft.itemId } }
            guard !tasks.isEmpty else { return }
            composer.drafting = true
            defer { if composer.target?.key == target.key { composer.drafting = false } }
            if isDemo {
                // As long as a real model would take, roughly.
                try? await Task.sleep(for: ((github as? DemoGitHubService)?.delay ?? .zero) * 3)
                suggestions = DemoData.issueSuggestions(for: tasks, labels: labels)
            } else if let (provider, model) = summaryProvider() {
                suggestions = try? await IssueDrafter.suggest(detail, tasks: tasks, target: target, labels: labels, myName: me?.name ?? myName, provider: provider, model: model)
                // Indices refer to `tasks`; turn them into the tasks' ids.
            }
            guard let found = suggestions else { return }
            let byItem = found.compactMap { suggestion -> IssueSuggestion? in
                guard tasks.indices.contains(suggestion.index), let id = tasks[suggestion.index].id else { return nil }
                var copy = suggestion
                copy.index = Int(id)
                return copy
            }
            suggestions = byItem
            githubSuggestions[key] = byItem
        }
        composer.draftedRepoId = target.repoId
        guard let suggestions, composer.target?.key == target.key else { return }
        for index in composer.drafts.indices {
            var draft = composer.drafts[index]
            guard let suggestion = suggestions.first(where: { Int64($0.index) == draft.itemId }) else { continue }
            draft.suggestion = suggestion
            let ids = suggestion.labels.compactMap { name in labels.first { $0.name == name }?.id }
            draft.suggestedLabelIds = ids
            if !draft.touchedLabels { draft.labelIds = ids }
            // A single task opened on its own is wanted, whatever the model thinks.
            if composer.only == nil, !draft.touchedInclude, !draft.isLink {
                draft.include = suggestion.include
                draft.note = suggestion.include ? nil : (suggestion.reason ?? String(localized: "Eher kein Repo-Thema", comment: "a task the language model thinks is not work for the GitHub repository"))
            }
            composer.drafts[index] = draft
        }
    }

    // MARK: Changing drafts

    public func toggleInclude(_ itemId: Int64, in composer: IssueComposer) {
        composer.update(itemId) { draft in
            draft.include.toggle()
            draft.touchedInclude = true
            if draft.include { draft.note = nil }
        }
    }

    public func setStatus(_ optionId: String, of itemId: Int64, in composer: IssueComposer) {
        composer.update(itemId) { draft in
            draft.statusId = optionId
            draft.touchedStatus = true
        }
    }

    public func toggleLabel(_ labelId: String, of itemId: Int64, in composer: IssueComposer) {
        composer.update(itemId) { draft in
            if let index = draft.labelIds.firstIndex(of: labelId) {
                draft.labelIds.remove(at: index)
            } else {
                draft.labelIds.append(labelId)
            }
            draft.touchedLabels = true
        }
    }

    public func toggleAssignee(_ user: GitHubUser, of itemId: Int64, in composer: IssueComposer) {
        composer.update(itemId) { draft in
            if let index = draft.assignees.firstIndex(where: { $0.id == user.id }) {
                draft.assignees.remove(at: index)
            } else {
                draft.assignees.append(user)
            }
            draft.touchedAssignees = true
        }
    }

    public func setLinking(_ link: Bool, of itemId: Int64, in composer: IssueComposer) {
        let project = githubProject(composer.target?.projectId)
        composer.update(itemId) { draft in
            guard let duplicate = draft.duplicate else { return }
            draft.mode = link ? .link(duplicate) : .create
            draft.touchedMode = true
            if link {
                let name = composer.target?.projectId.flatMap { duplicate.statuses[$0] }
                draft.statusId = project?.statusOptions.first { $0.name == name }?.id
            } else {
                draft.statusId = project?.defaultStatus?.id
            }
        }
    }

    // MARK: Creating

    /// Creates the issues (and saves the links) of the composer's checked tasks. Returns true when all went through.
    @discardableResult
    public func createIssues(from composer: IssueComposer) async -> Bool {
        guard let target = composer.target, composer.canCreate,
              let detail = try? database.detail(of: composer.meetingId) else { return false }
        composer.creating = true
        composer.error = nil
        defer { composer.creating = false }
        let project = githubProject(target.projectId)
        let withContext = composer.includeContext && target.isPrivate
        var created: [LinkedIssue] = []
        var linked = 0
        var problems: [String] = []
        for draft in composer.drafts where draft.include {
            guard let item = detail.actionItems.first(where: { $0.id == draft.itemId }), let itemId = item.id, item.issue == nil else { continue }
            let statusName = project?.statusOptions.first { $0.id == draft.statusId }?.name
            switch draft.mode {
            case .link(let ref):
                let issue = LinkedIssue(
                    id: ref.id, number: ref.number, url: ref.url, title: ref.title, repo: ref.repo, repoId: target.repoId,
                    projectId: target.projectId.flatMap { ref.projectItems[$0] == nil ? nil : $0 },
                    projectItemId: target.projectId.flatMap { ref.projectItems[$0] },
                    status: target.projectId.flatMap { ref.statuses[$0] }, state: ref.state, linkedExisting: true
                )
                try? database.setIssue(issue, of: itemId)
                linked += 1
            case .create:
                let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let new = NewIssue(
                    target: target,
                    title: title.isEmpty ? item.text : title,
                    body: IssueDrafter.body(suggestion: draft.suggestion, task: item, detail: detail, withContext: withContext),
                    assigneeIds: draft.assignees.map(\.id),
                    labelIds: draft.labelIds,
                    statusFieldId: project?.statusFieldId,
                    statusOptionId: draft.statusId
                )
                do {
                    let made = try await github.create(new)
                    let onProject = target.projectId != nil && made.projectItemId != nil
                    let issue = LinkedIssue(
                        id: made.id, number: made.number, url: made.url, title: new.title, repo: target.repo, repoId: target.repoId,
                        projectId: onProject ? target.projectId : nil, projectItemId: made.projectItemId,
                        status: onProject && made.projectError == nil ? statusName : nil
                    )
                    try? database.setIssue(issue, of: itemId)
                    created.append(issue)
                    if let problem = made.projectError {
                        problems.append(String(localized: "#\(made.number) ist angelegt, kam aber nicht ins Projekt: \(problem)", comment: "an issue was created but could not be added to its GitHub project; the reason follows"))
                    }
                    learnAccounts(from: draft, in: detail)
                } catch {
                    problems.append("„\(new.title)“: \(error.localizedDescription)")
                }
            }
        }
        if !created.isEmpty || linked > 0 {
            try? database.recordRoutes(TargetSuggester.keys(for: detail), target: target)
        }
        githubStatesCheckedAt[composer.meetingId] = Date()
        reportCreation(created: created, linked: linked, problems: problems, target: target)
        preparedComposers[composer.meetingId] = nil
        // What is left (tasks that failed) stays in the composer for another try.
        let done = Set((try? database.detail(of: composer.meetingId))?.actionItems.filter { $0.issue != nil }.compactMap(\.id) ?? [])
        composer.drafts.removeAll { done.contains($0.itemId) }
        composer.activeIndex = min(composer.activeIndex, max(composer.drafts.count - 1, 0))
        if !problems.isEmpty { composer.error = problems.joined(separator: "\n") }
        if problems.isEmpty, self.composer === composer { self.composer = nil }
        return problems.isEmpty
    }

    private func reportCreation(created: [LinkedIssue], linked: Int, problems: [String], target: GitHubTarget) {
        let made = created.isEmpty ? nil : (created.count == 1
            ? String(localized: "#\(created[0].number) angelegt", comment: "toast: one GitHub issue created, with its number")
            : String(localized: "\(created.count) Issues angelegt", comment: "plural: toast, GitHub issues created"))
        let joined = linked == 0 ? nil : String(localized: "\(linked) bestehende verknüpft", comment: "plural: tasks linked to GitHub issues that already existed")
        let title = made ?? (joined.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? String(localized: "Nichts angelegt", comment: "toast: no GitHub issue could be created"))
        var message = [target.title]
        if made != nil, let joined { message.append(joined) }
        if !problems.isEmpty {
            showToast(title, (message + problems).joined(separator: "\n"), isError: true)
        } else if made != nil || joined != nil {
            let url = created.count == 1 ? URL(string: created[0].url) : URL(string: "https://github.com/\(target.repo)/issues")
            showToast(title, message.joined(separator: " · "), action: url.map { .openURL($0) })
        }
    }

    /// The account a task's owner was assigned teaches the app who that person is on GitHub: the one found by
    /// name, or one picked by hand that fits the name (handing the task to someone else teaches nothing).
    private func learnAccounts(from draft: IssueDraft, in detail: MeetingDetail) {
        let owners = persons(forOwner: draft.owner, in: detail)
        guard owners.count == 1, draft.assignees.count == 1, let person = owners.first, !person.isMe else { return }
        let user = draft.assignees[0]
        guard person.github?.id != user.id else { return }
        if draft.touchedAssignees {
            guard IssueMatching.fits(user, name: person.name) else { return }
        } else if person.github != nil {
            return
        }
        try? database.setGitHub(user, of: person.id)
    }

    // MARK: Keeping tasks in step

    /// Reads the linked issues' state from GitHub: a closed issue checks off its task, a reopened one unchecks it.
    public func refreshLinkedIssues(of meetingId: String, force: Bool = false) async {
        guard isGitHubConnected || settings.githubLogin != nil else { return }
        if !force, let checked = githubStatesCheckedAt[meetingId], Date().timeIntervalSince(checked) < 60 { return }
        guard let detail = try? database.detail(of: meetingId) else { return }
        let linked = detail.actionItems.filter { $0.issue != nil }
        guard !linked.isEmpty else { return }
        githubStatesCheckedAt[meetingId] = Date()
        guard let states = try? await github.issueStates(ids: linked.compactMap { $0.issue?.id }) else { return }
        let byId = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in linked {
            guard let itemId = item.id, var issue = item.issue, let state = byId[issue.id] else { continue }
            let wasClosed = issue.isClosed
            issue.state = state.state
            issue.title = state.title.isEmpty ? issue.title : state.title
            if let project = issue.projectId {
                issue.status = state.statuses[project] ?? issue.status
                issue.projectItemId = state.projectItems[project] ?? issue.projectItemId
            } else if let (project, item) = state.projectItems.first {
                // Added to a project on GitHub in the meantime.
                issue.projectId = project
                issue.projectItemId = item
                issue.status = state.statuses[project]
            }
            issue.checkedAt = Date()
            let done: Bool? = wasClosed != issue.isClosed ? issue.isClosed : nil
            guard issue != item.issue || done != nil else { continue }
            try? database.setIssue(issue, of: itemId, done: done)
        }
    }

    /// Checking off a linked task closes its issue (and moves it to "Done"); unchecking reopens it.
    func setLinkedDone(_ item: ActionItem, done: Bool) {
        guard let itemId = item.id, var issue = item.issue else { return }
        try? database.setActionItem(itemId, done: done)
        let project = githubProject(issue.projectId)
        let option = done ? project?.doneStatus : project?.defaultStatus
        var status: (projectId: String, itemId: String, fieldId: String, optionId: String)?
        if let project, let projectItem = issue.projectItemId, let field = project.statusFieldId, let option {
            status = (project.id, projectItem, field, option.id)
        }
        Task {
            do {
                try await github.setDone(done, issueId: issue.id, status: status)
                issue.state = done ? "CLOSED" : "OPEN"
                if status != nil { issue.status = option?.name }
                try? database.setIssue(issue, of: itemId)
            } catch {
                try? database.setActionItem(itemId, done: !done)
                showToast(done ? String(localized: "Issue ließ sich nicht schließen") : String(localized: "Issue ließ sich nicht wieder öffnen"), error.localizedDescription, isError: true)
            }
        }
    }

    public func unlinkIssue(_ item: ActionItem) {
        guard let itemId = item.id else { return }
        try? database.setIssue(nil, of: itemId)
    }

    public func openIssue(_ issue: LinkedIssue) {
        if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
    }

    public func forgetRoute(_ route: GitHubRoute) {
        guard let id = route.id else { return }
        try? database.deleteRoute(id)
    }

    public func setGitHub(_ user: GitHubUser?, for person: Person) {
        try? database.setGitHub(user, of: person.id)
    }

    /// Asks the meeting screen to open the composer (for all open tasks, or one), after bringing the meeting up.
    public func requestComposer(for meetingId: String, item: Int64? = nil) {
        openMainWindow()
        select(meetingId)
        composerRequest = meetingId
        composerRequestItem = item
        composerRequestCount += 1
    }

    public func consumeComposerRequest() {
        composerRequest = nil
        composerRequestItem = nil
    }

    // MARK: After a summary

    /// When the tasks of a fresh summary have a remembered place, prepares them and offers to create them.
    func offerIssues(afterSummaryOf meetingId: String) async {
        guard !isDemo, let offer = await prepareOffer(for: meetingId) else { return }
        await notifications.notifyIssuesReady(meetingId: meetingId, title: offer.title, body: offer.body)
    }

    /// Prepares the composer for a notification and words it; nil when there is nothing to offer.
    func prepareOffer(for meetingId: String) async -> (title: String, body: String)? {
        guard settings.githubAskAfterSummary, settings.githubLogin != nil else { return nil }
        await refreshGitHubCatalog()
        guard isGitHubConnected, let detail = try? database.detail(of: meetingId),
              detail.actionItems.contains(where: { $0.issue == nil && !$0.done }),
              let best = targetSuggestions(for: detail).first, best.isRemembered else { return nil }
        let composer = makeComposer(for: detail, only: nil)
        guard !composer.drafts.isEmpty else { return nil }
        await prepare(composer)
        let total = composer.newCount + composer.linkCount
        let links = composer.linkCount
        guard total > 0, let target = composer.target else { return nil }
        preparedComposers[meetingId] = composer
        // "Web-App › acme/web-app: 3 Aufgaben bereit, eine davon gibt es dort schon."
        var body = target.title + ": " + String(localized: "\(total) Aufgaben bereit", comment: "plural: notification, tasks ready for GitHub (the place comes before it)")
        if links > 0 {
            body += ", " + String(localized: "\(links) davon gibt es dort schon", comment: "plural: notification, of those tasks this many already have an issue there (one: eine davon gibt es dort schon)")
        }
        body += "."
        return (String(localized: "\(Strings.quote(detail.meeting.title)) ist zusammengefasst", comment: "notification title: a meeting's summary is ready"), body)
    }

    /// "Anlegen" in the notification: creates what was prepared, without opening the app.
    func createPreparedIssues(_ meetingId: String) async {
        if let composer = preparedComposers[meetingId] {
            await createIssues(from: composer)
        } else {
            requestComposer(for: meetingId)
        }
    }
}
