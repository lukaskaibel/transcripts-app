import SwiftUI

/// The open tasks of every meeting, newest meetings first.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tasksOnlyMine") private var onlyMine = false
    /// The tasks on screen. A task checked off here stays (struck through) until the view comes back, so nothing
    /// jumps away under the pointer.
    @State private var shown: Set<Int64> = []

    var body: some View {
        let groups = groups
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(AppModel.Section.tasks.title).font(.uiSemibold)
                Text("\(groups.reduce(0) { $0 + $1.items.filter { !$0.done }.count })").foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    withAnimation(Theme.spring) { onlyMine.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person").font(.system(size: 11))
                        Text("Nur meine", comment: "tasks: show only the user's own")
                    }
                    .font(.small)
                    .foregroundStyle(onlyMine ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(onlyMine ? Theme.selectionFill : Theme.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help(onlyMine ? "Alle Aufgaben zeigen" : "Nur Aufgaben zeigen, die dir zugeordnet sind")
                .debugFrame("tasks.onlyMine")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: Theme.headerHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }

            if groups.isEmpty {
                EmptyState(systemImage: "checkmark.circle",
                           title: onlyMine ? String(localized: "Keine offenen Aufgaben für dich") : String(localized: "Keine offenen Aufgaben"),
                           message: String(localized: "Die Aufgaben aus den Zusammenfassungen deiner Meetings erscheinen hier."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups, id: \.row.id) { group in
                            MeetingTasks(row: group.row, items: group.items)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: openIds, initial: true) { _, open in
            shown.formUnion(open)
        }
    }

    /// Every open task, mine or all.
    private var openIds: Set<Int64> {
        Set(model.rows.flatMap { row in row.actionItems.filter { !$0.done && (!onlyMine || isMine($0)) }.compactMap(\.id) })
    }

    private var groups: [(row: MeetingRow, items: [ActionItem])] {
        model.rows.compactMap { row in
            let items = row.actionItems.filter { item in
                guard let id = item.id, !onlyMine || isMine(item) else { return false }
                return !item.done || shown.contains(id)
            }
            return items.isEmpty ? nil : (row, items)
        }
    }

    private func isMine(_ item: ActionItem) -> Bool {
        guard let owner = item.owner?.trimmingCharacters(in: .whitespaces).lowercased(), !owner.isEmpty else { return false }
        let name = model.myName.lowercased()
        let first = (model.me?.firstName ?? name.split(separator: " ").first.map(String.init) ?? name).lowercased()
        return owner == name || owner == first
    }
}

/// A meeting's tasks under its name, which opens the meeting.
private struct MeetingTasks: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow
    var items: [ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.select(row.id)
            } label: {
                HStack(spacing: 8) {
                    Text(row.meeting.title).font(.smallSemibold).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(TimeFormat.compactDay(row.meeting.startedAt)).font(.small).foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .help("Meeting öffnen")
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ActionItemRow(item: item, people: model.people)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
                        }
                }
            }
            .cardStyle()
        }
    }
}
