import AppKit
import SwiftUI

/// What the "Nach GitHub" dropdown shows: the way to connect, or the composer once connected.
struct GitHubPopover: View {
    @Environment(AppModel.self) private var model
    let meetingId: String
    let only: Int64?
    var width: CGFloat
    let close: () -> Void

    private var showsComposer: Bool {
        guard model.settings.githubLogin != nil else { return false }
        if case .failed = model.githubConnection, model.githubCatalog == nil { return false }
        return true
    }

    var body: some View {
        Group {
            if showsComposer {
                if let composer = model.composer, composer.meetingId == meetingId, composer.only == only {
                    IssueComposerView(composer: composer, width: width, close: close)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Wird vorbereitet …").foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: width, height: 120)
                }
            } else {
                GitHubConnectView()
            }
        }
        .task(id: showsComposer) {
            guard showsComposer else { return }
            if model.openComposer(meetingId: meetingId, only: only) == nil {
                // Nothing left to send (all tasks done or on GitHub).
                close()
            }
        }
    }
}

/// Signing in, inside the dropdown: with the GitHub CLI like Issues for GitHub, or with a code on github.com.
struct GitHubConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                GitHubMark(size: 18)
                Text("Mit GitHub verbinden").font(.uiSemibold)
            }
            Text("Dann landen die Aufgaben direkt als Issues in deinen Projekten. Transcripts braucht dieselben Rechte wie Issues for GitHub: Issues und Projekte.")
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if let code = model.githubDeviceCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(code.userCode)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Der Code ist kopiert. Füge ihn auf github.com ein, die Seite ist schon offen.")
                        .font(.small)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Wartet auf GitHub …").font(.small).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Abbrechen") { model.cancelGitHubDeviceFlow() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 14)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if model.githubCLIAvailable {
                        Button {
                            Task { await model.connectGitHubCLI() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.githubConnection == .connecting { ProgressView().controlSize(.mini) }
                                Text("GitHub-CLI verwenden")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.githubConnection == .connecting)
                        .accessibilityIdentifier("github.connect.cli")
                        .debugFrame("github.connect.cli")
                        Text("Nimmt die Anmeldung von „gh“ auf diesem Mac, wie Issues for GitHub.")
                            .font(.tiny)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if model.githubDeviceFlowAvailable {
                        Button("Im Browser anmelden") { model.startGitHubDeviceFlow() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    if !model.githubCLIAvailable && !model.githubDeviceFlowAvailable {
                        Text("Installiere die GitHub-CLI (brew install gh) und melde dich im Terminal mit „gh auth login“ an.")
                            .font(.small)
                            .foregroundStyle(Theme.textBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 14)
            }
            if case .failed(let message) = model.githubConnection {
                Text(message)
                    .font(.small)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .font(.ui)
        .foregroundStyle(Theme.text)
    }
}

/// The composer: where the tasks go, and for each task its status, title, labels and assignees. Works like a
/// new issue in Issues for GitHub, for several tasks at once.
struct IssueComposerView: View {
    @Environment(AppModel.self) private var model
    @Bindable var composer: IssueComposer
    var width: CGFloat
    let close: () -> Void

    enum PickerKind: Equatable {
        case target, status, labels, assignees
    }

    struct OpenPicker: Equatable {
        var kind: PickerKind
        var itemId: Int64?
    }

    enum Field: Hashable {
        case list
        case title(Int64)
    }

    @State private var openPicker: OpenPicker?
    @FocusState private var focus: Field?

    private var detail: MeetingDetail? {
        model.detail?.meeting.id == composer.meetingId ? model.detail : (try? model.database.detail(of: composer.meetingId))
    }

    private var project: GitHubProject? { model.githubProject(composer.target?.projectId) }
    private var statuses: [GitHubStatusOption] { project?.statusOptions ?? [] }
    private var glyphs: [String: StatusGlyph] { StatusGlyph.map(for: statuses) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if composer.drafts.isEmpty {
                Text("Alle Aufgaben sind schon auf GitHub.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
            } else {
                rows
            }
            if composer.target?.isPrivate == false {
                notice(String(localized: "Öffentliches Repository – Zitate und Kontext aus dem Transkript bleiben draußen, nur Titel, Labels und Fälligkeit gehen rüber."), systemImage: "globe")
            }
            if let error = composer.error {
                notice(error, systemImage: "exclamationmark.triangle")
            }
            footer
        }
        .frame(width: width)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            focus = .list
            offerTargetPicker()
        }
        .onChange(of: model.githubCatalog != nil) { offerTargetPicker() }
        .onChange(of: openPicker) { _, now in
            // Back to the list once a picker closes, so the keys work again.
            if now == nil, case .title = focus {} else if now == nil { focus = .list }
        }
        .accessibilityIdentifier("github.composer")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            GitHubMark(size: 15)
                .foregroundStyle(Theme.textBody)
            targetChip
            if let suggestion = composer.suggestion, composer.target?.key == suggestion.target.key {
                HStack(spacing: 5) {
                    SparkleMark(size: 9)
                    Text(suggestion.short).lineLimit(1)
                }
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .help(suggestion.reason)
            }
            if composer.target?.isPrivate == false { PublicBadge() }
            Spacer(minLength: 8)
            if composer.loadingMeta || composer.drafting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(composer.drafting ? "Labels werden vorgeschlagen …" : "Lädt …")
                }
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .transition(.opacity)
            }
            IconButton(systemName: "xmark", label: "Schließen (Esc)", size: 24) { close() }
                .debugFrame("github.close")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 48)
        .animation(Theme.quick, value: composer.drafting)
    }

    private var targetChip: some View {
        Button {
            openPicker = OpenPicker(kind: .target)
        } label: {
            HStack(spacing: 6) {
                if let target = composer.target {
                    TargetLabel(target: target)
                } else {
                    Text("Ziel wählen …").font(.small)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .hoverFill(active: openPicker?.kind == .target, fill: Theme.controlActive)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        }
        .buttonStyle(PlainPressStyle())
        .help("Wohin die Aufgaben gehen (Z)")
        .accessibilityIdentifier("github.target")
        .debugFrame("github.target")
        .dropdown(isPresented: binding(.target, nil)) { pickerClose in
            PickerList(placeholder: String(localized: "Projekt oder Repository …", comment: "search field: where the GitHub issues go"), items: targetItems, hint: "Z", width: 420, maxRows: 10,
                       onPick: { key in pickTarget(key) }, onClose: pickerClose)
        }
    }

    // MARK: Rows

    private var rows: some View {
        let content = VStack(spacing: 0) {
            ForEach(Array(composer.drafts.enumerated()), id: \.element.id) { index, draft in
                row(draft, index: index)
            }
        }
        return Group {
            if composer.drafts.count > 8 {
                ScrollView { content }.frame(height: 8 * 44)
            } else {
                content
            }
        }
    }

    private func row(_ draft: IssueDraft, index: Int) -> some View {
        let active = index == composer.activeIndex
        let id = draft.itemId
        return HStack(spacing: 8) {
            Button {
                model.toggleInclude(id, in: composer)
                composer.activeIndex = index
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(draft.include ? Theme.accentFill : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(draft.include ? Theme.accentFill : Theme.textTertiary, lineWidth: 1.5)
                    if draft.include {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .help(draft.include ? "Nicht übernehmen (Leertaste)" : "Übernehmen (Leertaste)")
            .accessibilityLabel(draft.include ? "Übernehmen, an" : "Übernehmen, aus")
            .accessibilityIdentifier("github.row.\(id).include")
            .debugFrame("github.row.\(id).include")
            .padding(.trailing, 2)

            statusPart(draft)
                .opacity(draft.include ? 1 : 0.45)

            if let ref = draft.linkedRef {
                HStack(spacing: 6) {
                    Text("#\(ref.number)").font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    Text(ref.title).lineLimit(1).truncationMode(.tail)
                    Text("schon offen").font(.tiny).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(ref.repo)#\(ref.number) gibt es schon. Verknüpfen statt neu anlegen.")
            } else {
                TextField("Titel", text: titleBinding(id))
                    .textFieldStyle(.plain)
                    .foregroundStyle(draft.include ? Theme.text : Theme.textTertiary)
                    .focused($focus, equals: .title(id))
                    .onSubmit { focus = .list }
                    .accessibilityIdentifier("github.row.\(id).title")
                    .debugFrame("github.row.\(id).title")
                    .frame(maxWidth: .infinity)
            }

            if draft.include, !draft.isLink {
                labelsPart(draft)
            } else if !draft.include, let note = draft.note {
                HStack(spacing: 4) {
                    SparkleMark(size: 8)
                    Text(note).lineLimit(1)
                }
                .font(.tiny)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            }

            if draft.duplicate != nil, draft.include {
                linkToggle(draft)
            }

            if let due = draft.due {
                Text(due).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
            }

            assigneePart(draft)
                .opacity(draft.include ? 1 : 0.45)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(active && focus == .list ? Theme.popoverActiveRow : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { if $0, openPicker == nil { composer.activeIndex = index } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github.row.\(id)")
    }

    @ViewBuilder
    private func statusPart(_ draft: IssueDraft) -> some View {
        let glyph = draft.statusId.flatMap { glyphs[$0] } ?? StatusGlyph.none
        let name = statuses.first { $0.id == draft.statusId }?.name
        if draft.isLink || statuses.isEmpty {
            StatusIcon(glyph: draft.isLink ? glyph : StatusGlyph(category: .unstarted, progress: 0, color: Theme.textBody))
                .frame(width: 20, height: 20)
                .help(draft.isLink ? "Status auf GitHub: \(name ?? "–")" : "Offen (das Repository gehört zu keinem Projekt mit Status)")
        } else {
            PartButton(help: "Status: \(name ?? "–") (S)", isOpen: binding(.status, draft.itemId), identifier: "github.row.\(draft.itemId).status") {
                StatusIcon(glyph: glyph).frame(width: 20, height: 20)
            } picker: { pickerClose in
                PickerList(
                    placeholder: String(localized: "Status ändern …", comment: "search field of the status picker"),
                    items: statuses.enumerated().map { index, option in
                        PickerItem(id: option.id, title: option.name, selected: option.id == draft.statusId,
                                   icon: AnyView(StatusIcon(glyph: glyphs[option.id] ?? .none)), shortcut: index < 9 ? "\(index + 1)" : nil)
                    },
                    hint: "S", width: 250,
                    footer: project.map { String(localized: "Status aus dem Projekt \(Strings.quote($0.title))", comment: "under the status picker: the GitHub project the statuses come from") },
                    onPick: { model.setStatus($0, of: draft.itemId, in: composer) },
                    onClose: pickerClose
                )
            }
        }
    }

    private func labelsPart(_ draft: IssueDraft) -> some View {
        let all = model.labels(for: composer.target)
        let chosen = draft.labelIds.compactMap { id in all.first { $0.id == id } }
        return PartButton(help: chosen.isEmpty ? "Labels (L)" : "Labels: \(chosen.map(\.name).joined(separator: ", ")) (L)", isOpen: binding(.labels, draft.itemId), identifier: "github.row.\(draft.itemId).labels") {
            HStack(spacing: 4) {
                if draft.labelsAreSuggested { SparkleMark(size: 8).help("Vom Modell vorgeschlagen") }
                if chosen.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "tag").font(.system(size: 10, weight: .medium))
                        Text("Labels")
                    }
                    .font(.tiny)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .frame(height: 20)
                } else {
                    ForEach(chosen.prefix(2)) { LabelChip(label: $0) }
                    if chosen.count > 2 {
                        Text("+\(chosen.count - 2)").font(.tiny).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .fixedSize()
        } picker: { pickerClose in
            PickerList(
                placeholder: String(localized: "Labels hinzufügen …", comment: "search field of the label picker"),
                items: all.map { label in
                    PickerItem(id: label.id, title: label.name, selected: currentDraft(draft.itemId)?.labelIds.contains(label.id) ?? false,
                               icon: AnyView(Circle().fill(Theme.labelColor(label.color)).frame(width: 9, height: 9)),
                               trailing: draft.suggestedLabelIds.contains(label.id) ? AnyView(HStack(spacing: 3) { SparkleMark(size: 8); Text("Vorschlag").font(.tiny).foregroundStyle(Theme.textSecondary) }) : nil)
                },
                hint: "L", staysOpen: true, width: 280,
                footer: all.isEmpty ? String(localized: "Das Repository hat keine Labels") : nil,
                onPick: { model.toggleLabel($0, of: draft.itemId, in: composer) },
                onClose: pickerClose
            )
        }
    }

    private func assigneePart(_ draft: IssueDraft) -> some View {
        let users = model.assignableUsers(for: composer.target)
        let inMeeting = detail.map { model.meetingUsers(for: $0, among: users) } ?? []
        let rest = users.filter { user in !inMeeting.contains { $0.id == user.id } }.sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        let assigned = draft.assignees
        let viewerId = model.githubViewer?.id
        func item(_ user: GitHubUser, header: String?) -> PickerItem {
            PickerItem(id: user.id, title: user.login, subtitle: user.name,
                       selected: currentDraft(draft.itemId)?.assignees.contains { $0.id == user.id } ?? false,
                       icon: AnyView(GitHubAvatar(user: user, size: 18)),
                       trailing: user.id == viewerId ? AnyView(Text("du").font(.tiny).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6).frame(height: 18).background(RoundedRectangle(cornerRadius: 4).fill(Theme.popoverSelected))) : nil,
                       header: header)
        }
        let items = inMeeting.enumerated().map { item($1, header: $0 == 0 ? String(localized: "Im Meeting", comment: "assignee picker section: GitHub accounts of the meeting's people") : nil) }
            + rest.enumerated().map { item($1, header: $0 == 0 ? (inMeeting.isEmpty ? nil : String(localized: "Weitere im Repository", comment: "assignee picker section: everyone else who can be assigned")) : nil) }
        let help: LocalizedStringKey = assigned.isEmpty ? "Niemand zugewiesen (A)" : "Zugewiesen an \(assigned.map(\.login).joined(separator: ", ")) (A)"
        return PartButton(help: help, round: true, isOpen: binding(.assignees, draft.itemId), identifier: "github.row.\(draft.itemId).assignees") {
            Group {
                if assigned.isEmpty {
                    Image(systemName: "person.crop.circle.dashed")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    GitHubAvatarStack(users: assigned)
                }
            }
            .frame(minWidth: 20, minHeight: 20)
        } picker: { pickerClose in
            PickerList(placeholder: String(localized: "Zuweisen an …", comment: "search field of the assignee picker"), items: items, hint: "A", staysOpen: true, width: 300,
                       footer: accountNote(for: draft),
                       onPick: { id in if let user = users.first(where: { $0.id == id }) { model.toggleAssignee(user, of: draft.itemId, in: composer) } },
                       onClose: pickerClose)
        }
    }

    /// "Miriam Okafor ist mit mokafor verknüpft".
    private func accountNote(for draft: IssueDraft) -> String? {
        guard let detail, let person = model.persons(forOwner: draft.owner, in: detail).first, !person.isMe else { return nil }
        if let github = person.github { return String(localized: "\(person.name) ist mit \(github.login) verknüpft", comment: "a person and their GitHub login") }
        return String(localized: "Wählst du das Konto von \(person.firstName), merkt sich die App das", comment: "under the assignee picker: the app learns a person's GitHub account from the choice")
    }

    private func linkToggle(_ draft: IssueDraft) -> some View {
        HStack(spacing: 0) {
            segment("Verknüpfen", on: draft.isLink, id: "github.row.\(draft.itemId).link") { model.setLinking(true, of: draft.itemId, in: composer) }
            segment("Neu", on: !draft.isLink, id: "github.row.\(draft.itemId).new") { model.setLinking(false, of: draft.itemId, in: composer) }
        }
        .padding(1)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        .fixedSize()
        .help(draft.duplicate.map { String(localized: "#\($0.number) \(Strings.quote($0.title)) sieht nach derselben Aufgabe aus", comment: "tooltip: an open GitHub issue, by number and title, that looks like the same task") } ?? "")
    }

    private func segment(_ title: LocalizedStringKey, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.tiny)
                .foregroundStyle(on ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.controlActive : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityIdentifier(id)
        .debugFrame(id)
    }

    // MARK: Footer

    private var footer: some View {
        let isPublic = composer.target?.isPrivate == false
        let withContext = composer.includeContext && !isPublic
        return HStack(spacing: 10) {
            Button {
                composer.includeContext.toggle()
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(withContext ? Theme.accentFill : .clear)
                        RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(withContext ? Theme.accentFill : Theme.textTertiary, lineWidth: 1.5)
                        if withContext { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 13, height: 13)
                    Text("Kontext aus dem Transkript")
                }
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .disabled(isPublic)
            .help(isPublic ? "Bei öffentlichen Repositories nie" : "Zwei Sätze Beschreibung und ein Zitat mit Zeitstempel")
            .accessibilityIdentifier("github.context")
            .debugFrame("github.context")
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                hint("S", "Status")
                hint("A", "Zuweisen")
                hint("L", "Labels")
            }
            Text("⌘↵").font(.tiny).foregroundStyle(Theme.textSecondary).padding(.leading, 4)
            Button(action: submit) {
                HStack(spacing: 6) {
                    if composer.creating { ProgressView().controlSize(.mini).tint(.white) }
                    Text(composer.creating ? String(localized: "Wird angelegt …", comment: "button while GitHub issues are being created") : composer.createTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!composer.canCreate)
            .accessibilityIdentifier("github.create")
            .debugFrame("github.create")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 52)
        .overlay(alignment: .top) { Rectangle().fill(Theme.popoverBorder).frame(height: 1) }
    }

    private func hint(_ key: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 16, minHeight: 16)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.keycapBorder, lineWidth: 1))
            Text(title).font(.tiny).foregroundStyle(Theme.textSecondary)
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.small)
        .foregroundStyle(Theme.noticeText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.noticeFill)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    // MARK: Pickers

    private var targetItems: [PickerItem] {
        guard let catalog = model.githubCatalog else {
            return composer.target.map { [PickerItem(id: $0.key, title: $0.projectTitle ?? $0.repo, subtitle: $0.projectTitle == nil ? nil : $0.repo, selected: true, icon: AnyView(ProjectSwatch(title: $0.projectTitle ?? $0.repo)))] } ?? []
        }
        let suggestions = detail.map { model.targetSuggestions(for: $0) } ?? []
        let suggested = Set(suggestions.prefix(3).map(\.target.key))
        func item(_ target: GitHubTarget, header: String?, detail: String?) -> PickerItem {
            PickerItem(
                id: target.key,
                title: target.projectTitle ?? target.repo,
                subtitle: target.projectTitle == nil ? nil : target.repo,
                detail: detail,
                selected: composer.target?.key == target.key,
                icon: target.projectTitle.map { AnyView(ProjectSwatch(title: $0, size: 11)) } ?? AnyView(Image(systemName: "book.closed").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)),
                trailing: target.isPrivate ? nil : AnyView(PublicBadge()),
                header: header
            )
        }
        let top = suggestions.prefix(3).enumerated().map { index, suggestion in
            item(suggestion.target, header: index == 0 ? String(localized: "Vorschläge", comment: "target picker section: remembered places") : nil, detail: suggestion.reason)
        }
        let others = catalog.targets.filter { !suggested.contains($0.key) }
        return top + others.enumerated().map { index, target in item(target, header: index == 0 && !top.isEmpty ? String(localized: "Alle", comment: "target picker section: every project and repository") : nil, detail: nil) }
    }

    private func pickTarget(_ key: String) {
        let suggestions = detail.map { model.targetSuggestions(for: $0) } ?? []
        guard let target = model.githubCatalog?.targets.first(where: { $0.key == key }) ?? suggestions.first(where: { $0.target.key == key })?.target else { return }
        model.setTarget(target, in: composer)
        if let suggestion = suggestions.first(where: { $0.target.key == key }) { composer.suggestion = suggestion }
    }

    private func binding(_ kind: PickerKind, _ itemId: Int64?) -> Binding<Bool> {
        Binding(
            get: { openPicker == OpenPicker(kind: kind, itemId: itemId) },
            set: { open in
                if open {
                    openPicker = OpenPicker(kind: kind, itemId: itemId)
                } else if openPicker == OpenPicker(kind: kind, itemId: itemId) {
                    openPicker = nil
                }
            }
        )
    }

    private func titleBinding(_ id: Int64) -> Binding<String> {
        Binding(
            get: { composer.drafts.first { $0.itemId == id }?.title ?? "" },
            set: { value in composer.update(id) { $0.title = value } }
        )
    }

    private func currentDraft(_ id: Int64) -> IssueDraft? {
        composer.drafts.first { $0.itemId == id }
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // A picker open on top has the keys (SwiftUI shows them to this view as well).
        guard openPicker == nil else { return .ignored }
        if press.key == .return, press.modifiers.contains(.command) {
            submit()
            return .handled
        }
        if case .title = focus {
            if press.key == .escape {
                focus = .list
                return .handled
            }
            return .ignored
        }
        let drafts = composer.drafts
        switch press.key {
        case .downArrow:
            composer.activeIndex = min(composer.activeIndex + 1, max(drafts.count - 1, 0))
            return .handled
        case .upArrow:
            composer.activeIndex = max(composer.activeIndex - 1, 0)
            return .handled
        case .space:
            if drafts.indices.contains(composer.activeIndex) { model.toggleInclude(drafts[composer.activeIndex].itemId, in: composer) }
            return .handled
        case .return:
            if drafts.indices.contains(composer.activeIndex), !drafts[composer.activeIndex].isLink {
                focus = .title(drafts[composer.activeIndex].itemId)
                // A field that takes focus selects all its text; typing should add to the title, not replace it.
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    }
                }
            }
            return .handled
        case .escape:
            close()
            return .handled
        default:
            break
        }
        guard press.modifiers.subtracting(.shift).isEmpty, drafts.indices.contains(composer.activeIndex) else { return .ignored }
        let draft = drafts[composer.activeIndex]
        switch press.characters.lowercased() {
        case "s" where !statuses.isEmpty && !draft.isLink:
            openPicker = OpenPicker(kind: .status, itemId: draft.itemId)
        case "a":
            openPicker = OpenPicker(kind: .assignees, itemId: draft.itemId)
        case "l" where draft.include && !draft.isLink:
            openPicker = OpenPicker(kind: .labels, itemId: draft.itemId)
        case "z":
            openPicker = OpenPicker(kind: .target)
        default:
            return .ignored
        }
        return .handled
    }

    /// Without a remembered place, the composer starts with the list of places open.
    private func offerTargetPicker() {
        guard composer.target == nil, model.githubCatalog != nil, openPicker == nil else { return }
        Task {
            // The panel has to be on screen before a dropdown can open from it.
            try? await Task.sleep(for: .milliseconds(200))
            if composer.target == nil, openPicker == nil { openPicker = OpenPicker(kind: .target) }
        }
    }

    private func submit() {
        guard composer.canCreate else { return }
        let composer = composer
        Task {
            if await model.createIssues(from: composer) { close() }
        }
    }
}
