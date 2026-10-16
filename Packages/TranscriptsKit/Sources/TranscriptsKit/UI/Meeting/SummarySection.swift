import SwiftUI

struct SummarySection: View {
    @Environment(AppModel.self) private var model
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
        VStack(alignment: .leading, spacing: 14) {
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
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.suggestion))
    }

    private func content(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary.overview)
                .font(.reading)
                .lineSpacing(5)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !summary.decisions.isEmpty {
                SummaryPart(title: String(localized: "Entscheidungen"), id: "decisions", text: SummaryText.bullets(summary.decisions)) {
                    BulletList(items: summary.decisions)
                }
            }
            if !detail.actionItems.isEmpty {
                TasksHeader(detail: detail)
                    .padding(.top, 26)
                ActionItemList(items: detail.actionItems, people: Array(detail.people.values) + model.people)
                    .padding(.top, 4)
            }
            if !summary.openQuestions.isEmpty {
                SummaryPart(title: String(localized: "Offene Fragen"), id: "questions", text: SummaryText.bullets(summary.openQuestions)) {
                    BulletList(items: summary.openQuestions)
                }
            }
            // The details last, so decisions and tasks stay at the top however long the meeting was.
            if !summary.topics.isEmpty {
                SummaryPart(title: String(localized: "Themen", comment: "the subjects a meeting went through, in its summary"), id: "topics",
                            text: SummaryText.topics(summary.topics)) {
                    TopicList(topics: summary.topics)
                }
            }
            footer(summary)
        }
    }

    /// Which model wrote it, and the ways to write it again or copy it, quietly under the summary.
    private func footer(_ summary: MeetingSummary) -> some View {
        HStack(spacing: 14) {
            Text("Zusammengefasst mit \(summary.model)", comment: "under a summary: the language model that wrote it")
                .lineLimit(1)
            Button("Neu erstellen") { Task { await model.generateSummary(detail.meeting.id) } }
                .disabled(!model.summaryProviderReady)
            Button("Kopieren") {
                model.copyToClipboard(SummaryText.markdown(detail), toast: String(localized: "Zusammenfassung kopiert", comment: "toast"))
            }
            .accessibilityIdentifier("summary.copy")
            .debugFrame("summary.copy")
            Spacer(minLength: 0)
        }
        .buttonStyle(PlainPressStyle())
        .font(.small)
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 32)
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

/// A part of the summary under its heading, with a button that copies it (on the Mac when the pointer is over it).
struct SummaryPart<Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let id: String
    /// What the button puts on the clipboard.
    let text: String
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.pageHeading).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                IconButton(systemName: "doc.on.doc", label: String(localized: "\(title) kopieren", comment: "button: copy one part of the summary, e.g. Entscheidungen kopieren"), size: 22, tint: Theme.textTertiary) {
                    model.copyToClipboard(text, toast: String(localized: "\(title) kopiert", comment: "toast: one part of the summary was copied, e.g. Entscheidungen kopiert"))
                }
                .opacity(hovering || Platform.isMobile ? 1 : 0)
                .accessibilityIdentifier("summary.\(id).copy")
                .debugFrame("summary.\(id).copy")
            }
            .frame(minHeight: 26)
            content
        }
        .padding(.top, 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The subjects the meeting went through, each with its points.
struct TopicList: View {
    let topics: [SummaryTopic]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
                VStack(alignment: .leading, spacing: 0) {
                    Text(topic.title)
                        .font(.reading.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !topic.points.isEmpty {
                        BulletList(items: topic.points)
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// "Aufgaben 1 von 4" and the button that copies them as a checklist.
struct TasksHeader: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Aufgaben").font(.pageHeading).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("\(detail.actionItems.filter(\.done).count) von \(detail.actionItems.count)")
                .font(.ui)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Button {
                model.copyToClipboard(SummaryText.tasks(detail.actionItems), toast: String(localized: "Aufgaben kopiert", comment: "toast"))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium))
                    Text("Kopieren")
                }
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .hoverFill()
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .help("Alle Aufgaben als Checkliste kopieren")
            .accessibilityIdentifier("summary.tasks.copy")
            .debugFrame("summary.tasks.copy")
        }
        .frame(minHeight: 28)
    }
}

/// A meeting's tasks as a checklist, as Notebook draws one: on the Mac plain lines on the page, on iPhone and iPad
/// in a group of their own.
struct ActionItemList: View {
    let items: [ActionItem]
    let people: [Person]

    var body: some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ActionItemRow(item: item, people: people)
                    .overlay(alignment: .top) {
                        if index > 0 && Platform.isMobile { Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.leading, 46) }
                    }
            }
        }
        if Platform.isMobile {
            list.cardStyle(radius: 14)
        } else {
            list.padding(.horizontal, -14)
        }
    }
}

struct ActionItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ActionItem
    let people: [Person]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleActionItem(item)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(item.done ? Theme.accent : .clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(item.done ? Theme.accent : Theme.textTertiary.opacity(0.7), lineWidth: 1.5)
                    if item.done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 17, height: 17)
                #if os(iOS)
                // Big enough for a finger, without moving the box.
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .padding(-10)
                #endif
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(item.done ? "Als offen markieren" : "Als erledigt markieren")
            .accessibilityIdentifier("task.\(item.id ?? 0).done")
            .debugFrame("task.\(item.id ?? 0).done")
            Text(item.text)
                .font(.reading)
                .strikethrough(item.done, color: Theme.textTertiary)
                .foregroundStyle(item.done ? Theme.textTertiary : Theme.text)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if !Platform.isMobile {
                // On iPhone and iPad copying is in the row's menu (a long press), as there is no pointer to show it on.
                IconButton(systemName: "doc.on.doc", label: String(localized: "Aufgabe kopieren"), size: 22, tint: Theme.textTertiary, action: copy)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityIdentifier("task.\(item.id ?? 0).copy")
                    .debugFrame("task.\(item.id ?? 0).copy")
            }
            if let who = ownerAndDue {
                Text(who).font(.ui).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Platform.isMobile ? 9 : 0)
        .frame(minHeight: Platform.isMobile ? 46 : 32)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Kopieren", systemImage: "doc.on.doc", action: copy)
            Button(item.done ? "Als offen markieren" : "Als erledigt markieren", systemImage: item.done ? "circle" : "checkmark.circle") {
                model.toggleActionItem(item)
            }
        }
    }

    private func copy() {
        model.copyToClipboard(SummaryText.task(item), toast: String(localized: "Aufgabe kopiert", comment: "toast"))
    }

    /// "Lukas · Mi.": whose task it is, by first name, and when it is due.
    private var ownerAndDue: String? {
        let owner = item.owner.map { owner in
            let lowered = owner.lowercased()
            return people.first(where: { $0.name.lowercased() == lowered || $0.firstName.lowercased() == lowered })?.firstName ?? owner
        }
        let parts = [owner, item.due].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
