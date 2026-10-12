#if os(iOS)
import SwiftUI

/// The open tasks of every meeting under the meeting's name, as on the Mac. A task checked off stays (struck
/// through) until the screen comes back, so nothing jumps away under the finger.
struct TasksScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("tasksOnlyMine") private var onlyMine = false
    @State private var shown: Set<Int64> = []

    var body: some View {
        let groups = model.taskGroups(onlyMine: onlyMine, keeping: shown)
        Group {
            if groups.isEmpty {
                MobileEmptyState(
                    systemImage: "checkmark.circle",
                    title: onlyMine ? String(localized: "Keine offenen Aufgaben für dich") : String(localized: "Keine offenen Aufgaben"),
                    message: String(localized: "Die Aufgaben aus den Zusammenfassungen deiner Meetings erscheinen hier.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groups, id: \.row.id) { group in
                            MeetingTasks(row: group.row, items: group.items)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .navigationTitle(AppModel.Section.tasks.title)
        .navigationSubtitle(subtitle(groups))
        .toolbar {
            SettingsToolbarItem()
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(Theme.spring) { onlyMine.toggle() }
                } label: {
                    Label {
                        Text("Nur meine", comment: "tasks: show only the user's own")
                    } icon: {
                        Image(systemName: onlyMine ? "person.fill" : "person")
                    }
                }
                .tint(onlyMine ? Theme.accent : nil)
                .accessibilityValue(onlyMine ? Text("Ein") : Text("Aus"))
                .accessibilityIdentifier("tasks.onlyMine")
            }
        }
        .onChange(of: model.openTaskIds(onlyMine: onlyMine), initial: true) { _, open in
            shown.formUnion(open)
        }
        .onDisappear { shown = [] }
    }

    private func subtitle(_ groups: [(row: MeetingRow, items: [ActionItem])]) -> String {
        let open = groups.reduce(0) { $0 + $1.items.filter { !$0.done }.count }
        return String(localized: "\(open) offen", comment: "plural: tasks not done yet")
    }
}
#endif
