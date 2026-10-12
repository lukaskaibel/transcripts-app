#if os(iOS)
import SwiftUI

/// Search, as the Mac's ⌘K: meetings by title, people, and every line of every transcript. Without a query it shows
/// the latest meetings.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    private var query: String {
        navigation.searchQuery.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        @Bindable var navigation = navigation
        let text = query.lowercased()
        let meetings = model.rows.filter { text.isEmpty || $0.meeting.title.lowercased().contains(text) }.prefix(text.isEmpty ? 8 : 20)
        let people = text.isEmpty ? [] : model.peopleStats.filter { $0.person.name.lowercased().contains(text) }.prefix(6)
        List {
            if !meetings.isEmpty {
                Section {
                    ForEach(meetings) { row in
                        Button {
                            model.focusedSegmentId = nil
                            navigation.open(meeting: row.id)
                        } label: {
                            MobileMeetingRow(row: row, showsDay: true)
                        }
                        .buttonStyle(RowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.panel)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    MobileSectionHeader(title: text.isEmpty ? String(localized: "Letzte Meetings") : String(localized: "Meetings"))
                }
            }
            if !people.isEmpty {
                Section {
                    ForEach(Array(people)) { stats in
                        Button {
                            navigation.open(person: stats.person.id)
                        } label: {
                            MobilePersonRow(stats: stats)
                        }
                        .buttonStyle(RowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.panel)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Personen"))
                }
            }
            if !hits.isEmpty {
                Section {
                    ForEach(hits) { hit in
                        Button {
                            model.focusedSegmentId = hit.segment.id
                            navigation.open(meeting: hit.segment.meetingId)
                        } label: {
                            hitRow(hit)
                        }
                        .buttonStyle(RowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.panel)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Im Transkript", comment: "command palette section: lines found in transcripts"), count: hits.count)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .overlay {
            if !text.isEmpty, meetings.isEmpty, people.isEmpty, hits.isEmpty {
                MobileEmptyState(systemImage: "magnifyingglass", title: String(localized: "Nichts gefunden"), message: String(localized: "Gesucht wird in den Titeln, den Personen und in jeder Zeile der Transkripte."))
            } else if model.rows.isEmpty {
                MobileEmptyState(systemImage: "magnifyingglass", title: String(localized: "Noch nichts zu durchsuchen"), message: String(localized: "Sobald ein Meeting transkribiert ist, findest du hier jedes gesagte Wort."))
            }
        }
        .background(Theme.panel)
        .navigationTitle(String(localized: "Suchen"))
        .searchable(text: $navigation.searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Meetings, Personen, Gesagtes"))
        .searchFocused($focused)
        .onChange(of: navigation.searchQuery, initial: true) { _, text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            hits = trimmed.isEmpty ? [] : ((try? model.database.search(trimmed, limit: 30)) ?? [])
        }
        .onChange(of: navigation.searchFocusRequest) { focused = true }
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 16)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(SearchSnippet.attributed(hit.snippet))
                    .font(.ui)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text("\(hit.meetingTitle) · \(TimeFormat.compactDay(hit.meetingDate)) · \(TimeFormat.clock(hit.segment.start))")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
