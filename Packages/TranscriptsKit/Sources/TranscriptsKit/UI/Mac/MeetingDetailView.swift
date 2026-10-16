#if os(macOS)
import AppKit
import SwiftUI

/// A meeting as a page, like a note in Notebook: the title, then the summary or the transcript (switched in the
/// toolbar), and the facts and the people in the inspector.
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var deleting = false
    @State private var tab: MeetingTab
    @AppStorage("showsMeetingInspector") private var showsInspector = true

    init(detail: MeetingDetail) {
        self.detail = detail
        _tab = State(initialValue: MeetingTab.initial(for: detail))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock
                    StatusBanner(detail: detail)
                    VoicesBanner(detail: detail)
                    switch tab {
                    case .summary:
                        SummarySection(detail: detail)
                    case .transcript:
                        TranscriptSection(detail: detail)
                    }
                }
                .padding(.horizontal, 64)
                .padding(.top, 30)
                .padding(.bottom, 96)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.focusedSegmentId, initial: true) { _, id in
                guard let id else { return }
                tab = .transcript
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.player.meetingId == detail.meeting.id {
                PlayerBar()
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .animation(Theme.overlay, value: model.player.meetingId)
        .inspector(isPresented: $showsInspector) {
            Inspector(detail: detail)
                .inspectorColumnWidth(min: 220, ideal: 260, max: 380)
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .navigationTitle(detail.meeting.title)
        .onKeyPress(.escape) {
            guard model.overlay == nil else { return .ignored }
            model.goBack()
            return .handled
        }
        .onChange(of: detail.summary?.createdAt, initial: true) { _, written in
            if let written { model.markSummaryRead(detail.meeting.id, written: written) }
        }
        .showsSummaryWhenItArrives(detail, tab: $tab)
        .confirmationDialog("„\(detail.meeting.title)“ löschen?", isPresented: $deleting) {
            Button("Löschen", role: .destructive) { model.deleteMeeting(detail.meeting.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Zurück", systemImage: "chevron.left")
            }
            .help(model.backSection == nil ? String(localized: "Zurück zu den Meetings (Esc)") : String(localized: "Zurück (Esc)"))
        }
        ToolbarItem(placement: .principal) {
            MeetingTabPicker(tab: $tab)
        }
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            Menu {
                Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                    model.copyToClipboard(model.markdown(for: detail), toast: String(localized: "Meeting kopiert", comment: "toast: the whole meeting was copied as Markdown"))
                }
                if detail.summary != nil {
                    Button("Zusammenfassung kopieren", systemImage: "text.quote") {
                        model.copyToClipboard(SummaryText.markdown(detail), toast: String(localized: "Zusammenfassung kopiert", comment: "toast"))
                    }
                }
                Button("Als Markdown sichern …", systemImage: "square.and.arrow.down") { model.exportMarkdown(detail) }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Exportieren")
            .disabled(detail.segments.isEmpty)
            Menu {
                MeetingMenuItems(meetingId: detail.meeting.id) { deleting = true }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Mehr")
        }
        ToolbarSpacer(.fixed)
        SearchToolbarItem(model: model)
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                withAnimation(Theme.spring) { showsInspector.toggle() }
            } label: {
                Label(showsInspector ? String(localized: "Informationen ausblenden") : String(localized: "Informationen einblenden"), systemImage: "sidebar.right")
            }
            .help(showsInspector ? String(localized: "Informationen ausblenden (⌃⌘I)") : String(localized: "Informationen einblenden (⌃⌘I)"))
            .keyboardShortcut("i", modifiers: [.command, .control])
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditableText(text: detail.meeting.title, font: .pageTitle) { model.rename(meetingId: detail.meeting.id, to: $0) }
            Text(metaLine)
                .font(.ui)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 22)
    }

    private var metaLine: String {
        var parts = [TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)]
        if let source = detail.meeting.source { parts.append(source) }
        if detail.meeting.origin == .importedFile { parts.append(String(localized: "Importiert", comment: "the meeting comes from an imported audio file")) }
        return parts.joined(separator: " · ")
    }
}

extension AppModel {
    /// The meeting before or after the one on screen, in the list's order.
    func stepMeeting(by offset: Int) {
        guard let id = selectedMeetingId, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rows.indices.contains(target) else { return }
        selectedMeetingId = rows[target].id
    }
}
#endif
