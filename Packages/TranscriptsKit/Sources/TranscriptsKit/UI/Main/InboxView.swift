import SwiftUI

/// What waits for the user after their meetings: new summaries, tasks for GitHub, voices without a name.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var allVoices = false

    private static let voicesShown = 5

    var body: some View {
        let inbox = model.inbox
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(AppModel.Section.inbox.title).font(.uiSemibold)
                Text("\(inbox.count)").foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: Theme.headerHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }

            if inbox.isEmpty {
                EmptyState(systemImage: "tray", title: String(localized: "Alles erledigt", comment: "empty inbox"),
                           message: String(localized: "Neue Zusammenfassungen, Aufgaben für GitHub und Stimmen ohne Namen landen hier."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !inbox.summaries.isEmpty {
                            SectionHeader(title: String(localized: "Neue Zusammenfassungen"), count: inbox.summaries.count)
                            separated(inbox.summaries) { SummaryEntry(row: $0) }
                        }
                        if !inbox.github.isEmpty {
                            SectionHeader(title: String(localized: "Aufgaben für GitHub"), count: inbox.github.count)
                                .padding(.top, inbox.summaries.isEmpty ? 0 : 14)
                            separated(inbox.github) { GitHubEntry(row: $0) }
                        }
                        if !inbox.voices.isEmpty {
                            voicesHeader(count: inbox.voices.count)
                                .padding(.top, inbox.summaries.isEmpty && inbox.github.isEmpty ? 0 : 14)
                            let shown = allVoices ? inbox.voices : Array(inbox.voices.prefix(Self.voicesShown))
                            separated(shown) { ReviewRow(review: $0) }
                            if shown.count < inbox.voices.count {
                                Button {
                                    withAnimation(Theme.spring) { allVoices = true }
                                } label: {
                                    Text(String(localized: "\(inbox.voices.count - shown.count) weitere zeigen", comment: "plural: inbox, show the other voices"))
                                        .font(.small)
                                        .foregroundStyle(Theme.textSecondary)
                                        .padding(.horizontal, 14)
                                        .frame(height: 32)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func voicesHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("Stimmen benennen").font(.uiSemibold)
            Text("\(count)").foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Alle durchgehen") { model.startNaming() }
                .buttonStyle(PrimaryButtonStyle())
                .help("Eine Stimme nach der anderen anhören und benennen")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
    }

    private func separated<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        ForEach(items) { item in
            row(item)
            if item.id != items.last?.id {
                Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.horizontal, 14)
            }
        }
    }
}

/// One inbox entry: a symbol, what it is about, and what can be done about it.
private struct InboxEntry<Lead: View, Actions: View>: View {
    var title: String
    var detail: String
    var open: () -> Void
    @ViewBuilder var lead: Lead
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    lead
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.uiMedium).lineLimit(1)
                        Text(detail).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SummaryEntry: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow

    var body: some View {
        InboxEntry(title: row.meeting.title, detail: detail) {
            model.select(row.id)
        } lead: {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
        } actions: {
            Button("Öffnen") { model.select(row.id) }
                .buttonStyle(SecondaryButtonStyle())
            IconButton(systemName: "checkmark", label: String(localized: "Als gelesen markieren")) {
                if let written = row.summaryCreatedAt { model.markSummaryRead(row.id, written: written) }
            }
        }
        .debugFrame("inbox.summary.\(row.id)")
    }

    private var detail: String {
        let when = "\(TimeFormat.compactDay(row.meeting.startedAt)), \(TimeFormat.time(row.meeting.startedAt))"
        guard let overview = row.summaryOverview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else { return when }
        return "\(when) · \(overview)"
    }
}

private struct GitHubEntry: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow

    var body: some View {
        InboxEntry(title: row.meeting.title,
                   detail: String(localized: "\(row.unsentTasks) Aufgaben noch nicht auf GitHub", comment: "plural: inbox, open tasks of a meeting that are not on GitHub")) {
            model.select(row.id)
        } lead: {
            GitHubMark(size: 13).foregroundStyle(Theme.textSecondary)
        } actions: {
            Button("Nach GitHub …") { model.requestComposer(for: row.id) }
                .buttonStyle(PrimaryButtonStyle())
            IconButton(systemName: "xmark", label: String(localized: "Ignorieren")) {
                model.dismissGitHubTasks(row.id)
            }
        }
        .debugFrame("inbox.github.\(row.id)")
    }
}
