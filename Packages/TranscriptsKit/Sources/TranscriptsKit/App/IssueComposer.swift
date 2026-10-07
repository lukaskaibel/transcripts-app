import Foundation
import Observation

/// The GitHub connection as the settings and the composer show it.
public enum GitHubConnection: Equatable, Sendable {
    case signedOut
    case connecting
    case connected(GitHubUser)
    case failed(String)

    public var user: GitHubUser? {
        if case .connected(let user) = self { return user }
        return nil
    }
}

/// One task in the composer: what becomes of it on GitHub.
public struct IssueDraft: Identifiable, Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// A new issue.
        case create
        /// The task is this existing issue; only the link is saved.
        case link(GitHubIssueRef)
    }

    public var itemId: Int64
    public var id: Int64 { itemId }
    /// The task as the summary has it.
    public var text: String
    public var owner: String?
    public var due: String?

    public var include: Bool
    public var title: String
    public var statusId: String?
    public var labelIds: [String]
    public var assignees: [GitHubUser]
    public var mode: Mode
    /// An open issue that looks like the same task.
    public var duplicate: GitHubIssueRef?
    /// What the language model proposed, for the labels' mark and the description.
    public var suggestion: IssueSuggestion?
    public var suggestedLabelIds: [String]
    /// Why the task is left out ("Eher kein Repo-Thema").
    public var note: String?

    // What the user changed by hand; a late suggestion never overrides it.
    var touchedInclude = false
    var touchedLabels = false
    var touchedAssignees = false
    var touchedStatus = false
    var touchedMode = false

    public init(item: ActionItem) {
        itemId = item.id ?? 0
        text = item.text
        owner = item.owner
        due = item.due
        include = true
        title = item.text
        statusId = nil
        labelIds = []
        assignees = []
        mode = .create
        duplicate = nil
        suggestion = nil
        suggestedLabelIds = []
        note = nil
    }

    public var isLink: Bool {
        if case .link = mode { return true }
        return false
    }

    public var linkedRef: GitHubIssueRef? {
        if case .link(let ref) = mode { return ref }
        return nil
    }

    /// The labels are still exactly what the model proposed.
    public var labelsAreSuggested: Bool {
        !labelIds.isEmpty && !touchedLabels && labelIds == suggestedLabelIds
    }
}

/// The open "Nach GitHub" popover: where the tasks of a meeting go and what each one becomes.
@MainActor
@Observable
public final class IssueComposer: Identifiable {
    public let id = UUID()
    public let meetingId: String
    /// Set when the composer was opened for one task only.
    public let only: Int64?
    public var target: GitHubTarget?
    /// Why the target was proposed, while it is still the proposed one.
    public var suggestion: TargetSuggestion?
    public var drafts: [IssueDraft]
    public var includeContext: Bool
    /// The row the keyboard works on.
    public var activeIndex = 0
    /// Loading the target's labels and people.
    public var loadingMeta = false
    /// The language model is preparing labels and descriptions.
    public var drafting = false
    public var creating = false
    public var error: String?
    /// The repository the model's suggestions are for.
    var draftedRepoId: String?
    /// The target the drafts' statuses, people and duplicates were last worked out for.
    var preparedTargetKey: String?

    init(meetingId: String, only: Int64?, drafts: [IssueDraft], includeContext: Bool) {
        self.meetingId = meetingId
        self.only = only
        self.drafts = drafts
        self.includeContext = includeContext
    }

    public var newCount: Int { drafts.filter { $0.include && !$0.isLink }.count }
    public var linkCount: Int { drafts.filter { $0.include && $0.isLink }.count }

    /// "2 Issues anlegen", "2 anlegen · 1 verknüpfen", "Verknüpfen".
    public var createTitle: String {
        let made = newCount, linked = linkCount
        if made > 0 && linked > 0 {
            return String(localized: "\(made) anlegen", comment: "plural: button part, new GitHub issues to create") + " · "
                + String(localized: "\(linked) verknüpfen", comment: "plural: button part, tasks to link to existing GitHub issues")
        }
        if made > 0 { return String(localized: "\(made) Issues anlegen", comment: "plural: button, create this many GitHub issues (one: Issue anlegen)") }
        if linked > 0 { return String(localized: "\(linked) Issues verknüpfen", comment: "plural: button, link tasks to existing GitHub issues (one: Verknüpfen)") }
        return String(localized: "Nichts ausgewählt", comment: "button while no task is checked")
    }

    public var canCreate: Bool { target != nil && newCount + linkCount > 0 && !creating }

    func index(of itemId: Int64) -> Int? {
        drafts.firstIndex { $0.itemId == itemId }
    }

    func update(_ itemId: Int64, _ change: (inout IssueDraft) -> Void) {
        guard let index = index(of: itemId) else { return }
        change(&drafts[index])
    }
}
