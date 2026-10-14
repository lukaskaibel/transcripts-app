#if os(iOS)
import SwiftUI

/// What waits after the meetings, as on the Mac: new summaries and voices without a name. A tap opens the meeting
/// (beside the list on a wide iPad); a swipe marks a summary read.
struct InboxScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide
    @State private var allVoices = false

    private static let voicesShown = 5

    var body: some View {
        let inbox = model.inbox
        Group {
            if inbox.isEmpty {
                MobileEmptyState(
                    systemImage: "tray",
                    title: String(localized: "Alles erledigt", comment: "empty inbox"),
                    message: String(localized: "Neue Zusammenfassungen und Stimmen ohne Namen landen hier.")
                )
            } else {
                list(inbox)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .navigationTitle(AppModel.Section.inbox.title)
        .toolbar { SettingsToolbarItem() }
    }

    private func list(_ inbox: Inbox) -> some View {
        List {
            if !inbox.summaries.isEmpty {
                Section {
                    ForEach(inbox.summaries) { row in
                        summaryRow(row)
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Neue Zusammenfassungen"), count: inbox.summaries.count)
                }
            }
            if !inbox.voices.isEmpty {
                Section {
                    let shown = allVoices ? inbox.voices : Array(inbox.voices.prefix(Self.voicesShown))
                    ForEach(shown) { review in
                        MobileReviewRow(review: review)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Theme.panel)
                            .listRowSeparator(.hidden)
                    }
                    if shown.count < inbox.voices.count {
                        Button {
                            withAnimation(Theme.spring) { allVoices = true }
                        } label: {
                            Text(String(localized: "\(inbox.voices.count - shown.count) weitere zeigen", comment: "plural: inbox, show the other voices"))
                                .font(.small)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.panel)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Stimmen benennen"), count: inbox.voices.count) {
                        Button("Alle durchgehen") { model.startNaming() }
                            .font(.smallMedium)
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("inbox.nameAll")
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .animation(Theme.spring, value: inbox)
    }

    private func summaryRow(_ row: MeetingRow) -> some View {
        let selected = wide && navigation.meetingInSplit[.inbox] == row.id
        return Button {
            navigation.open(meeting: row.id)
        } label: {
            InboxRowLabel(title: row.meeting.title, detail: summaryDetail(row), lines: 2) {
                Image(systemName: "sparkle").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(selected ? Theme.selected : Theme.panel)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if let written = row.summaryCreatedAt { model.markSummaryRead(row.id, written: written) }
            } label: {
                Label("Als gelesen markieren", systemImage: "checkmark")
            }
            .tint(Theme.accentFill)
        }
        .contextMenu {
            Button("Öffnen", systemImage: "doc.text") { navigation.open(meeting: row.id) }
            Button("Als gelesen markieren", systemImage: "checkmark") {
                if let written = row.summaryCreatedAt { model.markSummaryRead(row.id, written: written) }
            }
        }
        .accessibilityIdentifier("inbox.summary.\(row.id)")
    }

    private func summaryDetail(_ row: MeetingRow) -> String {
        let when = "\(TimeFormat.compactDay(row.meeting.startedAt)), \(TimeFormat.time(row.meeting.startedAt))"
        guard let overview = row.summaryOverview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else { return when }
        return "\(when) · \(overview)"
    }
}

/// One inbox entry: a symbol in a square, what it is about, and a line or two of detail.
struct InboxRowLabel<Lead: View>: View {
    var title: String
    var detail: String
    var lines = 1
    @ViewBuilder var lead: Lead

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            lead
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.uiMedium).foregroundStyle(Theme.text).lineLimit(2)
                Text(detail).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(lines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary.opacity(0.6))
                .padding(.top, 8)
        }
        .padding(.vertical, 11)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
