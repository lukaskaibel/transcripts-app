import AppKit
import SwiftUI

struct SummarySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let detail: MeetingDetail

    var body: some View {
        if detail.meeting.status == .ready || detail.summary != nil {
            Group {
                if model.isSummarizing(detail.meeting.id) {
                    generating
                } else if let summary = detail.summary {
                    content(summary)
                } else if !detail.segments.isEmpty {
                    empty
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: States

    private var generating: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(trailing: AnyView(EmptyView()))
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.settings.summaryProvider.flatMap { model.modelName(for: $0) }.map { String(localized: "Wird mit \($0) zusammengefasst …") } ?? String(localized: "Wird mit dem Modell zusammengefasst …"))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0.95, 0.85, 0.6], id: \.self) { width in
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4).fill(Theme.groupHeader).frame(width: proxy.size.width * width, height: 10)
                    }
                    .frame(height: 10)
                }
            }
            .frame(maxWidth: 560)
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textTertiary)
            if model.summaryProviderReady, let kind = model.settings.summaryProvider {
                Text("Noch keine Zusammenfassung").foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                ModelMenu(kind: kind)
                Button("Erstellen") { Task { await model.generateSummary(detail.meeting.id) } }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Text("Für Zusammenfassungen ein KI-Modell einrichten").foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button("Einrichten …") {
                    model.request(.settings(.ai))
                    openSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 46)
        .cardStyle()
    }

    private func content(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(trailing: AnyView(HStack(spacing: 2) {
                Text(summary.model).font(.small).foregroundStyle(Theme.textTertiary).padding(.trailing, 4)
                IconButton(systemName: "arrow.clockwise", label: String(localized: "Neu erstellen")) {
                    Task { await model.generateSummary(detail.meeting.id) }
                }
                .disabled(!model.summaryProviderReady)
                IconButton(systemName: "doc.on.doc", label: String(localized: "Kopieren")) {
                    model.copyToClipboard(model.summaryText(for: detail), toast: String(localized: "Zusammenfassung kopiert", comment: "toast"))
                }
            }))
            Text(summary.overview)
                .font(.reading)
                .lineSpacing(4)
                .foregroundStyle(Theme.textBody)
                .textSelection(.enabled)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.decisions.isEmpty {
                subheading("Entscheidungen")
                BulletList(items: summary.decisions)
            }
            if !detail.actionItems.isEmpty {
                TasksHeader(detail: detail)
                    .padding(.top, 14)
                ActionItemList(detail: detail, items: detail.actionItems, people: Array(detail.people.values) + model.people)
                    .padding(.top, 4)
            }
            if !summary.openQuestions.isEmpty {
                subheading("Offene Fragen")
                BulletList(items: summary.openQuestions)
            }
        }
    }

    private func header(trailing: AnyView) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            Text("Zusammenfassung").font(.uiSemibold)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 26)
    }

    private func subheading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.smallSemibold)
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 20)
    }
}

/// A menu with the summary models of a provider.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let kind: ProviderKind

    var body: some View {
        Menu {
            ForEach(model.providerModels[kind] ?? []) { option in
                Button {
                    model.choose(model: option.id, for: kind)
                } label: {
                    if option.id == model.model(for: kind) {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
            if (model.providerModels[kind] ?? []).isEmpty {
                Text("Modelle werden geladen …")
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.modelName(for: kind) ?? kind.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.small)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .task { if model.providerModels[kind] == nil { await model.checkProvider(kind) } }
    }
}

struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Theme.textTertiary).frame(width: 4, height: 4).offset(y: -3)
                    Text(item)
                        .font(.reading)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textBody)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
    }
}

/// "Aufgaben 1 von 4" and the button that sends them to GitHub.
struct TasksHeader: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var open = false
    @State private var width: CGFloat = 640

    private var unsent: Int { detail.actionItems.filter { $0.issue == nil && !$0.done }.count }

    var body: some View {
        HStack(spacing: 8) {
            Text("Aufgaben").font(.smallSemibold).foregroundStyle(Theme.textSecondary)
            Text("\(detail.actionItems.filter(\.done).count) von \(detail.actionItems.count)")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            if unsent > 0 || open {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 6) {
                        GitHubMark(size: 13)
                        Text("Nach GitHub")
                    }
                    .font(.small)
                    .foregroundStyle(Theme.textBody)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .hoverFill(active: open, fill: Theme.controlActive)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help("Offene Aufgaben als GitHub-Issues anlegen (⇧⌘G)")
                .accessibilityIdentifier("github.open")
                .debugFrame("github.open")
            } else if detail.actionItems.contains(where: { $0.issue != nil }) {
                HStack(spacing: 5) {
                    GitHubMark(size: 12)
                    Text("Alle auf GitHub")
                }
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 28)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .dropdown(isPresented: $open) { close in
            GitHubPopover(meetingId: detail.meeting.id, only: nil, width: max(620, width + 8), close: close)
        }
        .onChange(of: model.composerRequestCount, initial: true) {
            guard model.composerRequest == detail.meeting.id, model.composerRequestItem == nil else { return }
            model.consumeComposerRequest()
            // Give the window a moment to come up after a notification.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                open = true
            }
        }
    }
}

struct ActionItemList: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let items: [ActionItem]
    let people: [Person]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ActionItemRow(item: item, people: people)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
                    }
            }
        }
        .cardStyle()
        .task(id: detail.meeting.id) {
            await model.refreshLinkedIssues(of: detail.meeting.id)
        }
    }
}

struct ActionItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ActionItem
    let people: [Person]
    @State private var hovering = false
    @State private var open = false
    @State private var width: CGFloat = 640

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleActionItem(item)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(item.done ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(item.done ? Theme.accent : Theme.textTertiary, lineWidth: 1.5)
                    if item.done {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onColor)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(item.done ? "Als offen markieren" : "Als erledigt markieren")
            .help(item.issue == nil ? "" : (item.done ? "Als offen markieren – öffnet das Issue wieder" : "Als erledigt markieren – schließt das Issue auf GitHub") as LocalizedStringKey)
            .accessibilityIdentifier("task.\(item.id ?? 0).done")
            .debugFrame("task.\(item.id ?? 0).done")
            Text(item.text)
                .strikethrough(item.done, color: Theme.textTertiary)
                .foregroundStyle(item.done ? Theme.textTertiary : Theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let issue = item.issue {
                IssuePill(issue: issue)
            } else if !item.done {
                Button {
                    open = true
                } label: {
                    GitHubMark(size: 13)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(open ? Theme.partHover : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .opacity(hovering || open ? 1 : 0)
                .help("Diese Aufgabe nach GitHub …")
                .accessibilityIdentifier("task.\(item.id ?? 0).github")
                .debugFrame("task.\(item.id ?? 0).github")
            }
            if let due = item.due {
                Text(due).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            if let owner = item.owner {
                Avatar(kind: kind(for: owner), size: 18)
                    .help(owner)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .dropdown(isPresented: $open) { close in
            GitHubPopover(meetingId: item.meetingId, only: item.id, width: max(620, width + 8), close: close)
        }
        .onChange(of: model.composerRequestCount) {
            guard model.composerRequest == item.meetingId, let id = item.id, model.composerRequestItem == id else { return }
            model.consumeComposerRequest()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                open = true
            }
        }
        .contextMenu {
            if let issue = item.issue {
                Button("Auf GitHub öffnen", systemImage: "arrow.up.right.square") { model.openIssue(issue) }
                Button("Link kopieren", systemImage: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.url, forType: .string)
                }
                Divider()
                Button("Verknüpfung mit \(issue.reference) lösen", systemImage: "xmark.circle") { model.unlinkIssue(item) }
            } else if !item.done {
                Button("Nach GitHub …", systemImage: "arrow.up.forward.app") { open = true }
            }
        }
    }

    private func kind(for owner: String) -> Avatar.Kind {
        let lowered = owner.lowercased()
        if let person = people.first(where: { $0.name.lowercased() == lowered || $0.firstName.lowercased() == lowered }) {
            return person.isMe ? .me(name: person.name) : .person(name: person.name)
        }
        return .person(name: owner)
    }
}
