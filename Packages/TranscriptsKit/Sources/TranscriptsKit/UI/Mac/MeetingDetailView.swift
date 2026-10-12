#if os(macOS)
import AppKit
import SwiftUI

struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                titleBlock
                                StatusBanner(detail: detail)
                                VoicesBanner(detail: detail)
                                SummarySection(detail: detail)
                                TranscriptSection(detail: detail)
                            }
                            .padding(.horizontal, 44)
                            .padding(.top, 30)
                            .padding(.bottom, 40)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: model.focusedSegmentId, initial: true) { _, id in
                            guard let id else { return }
                            Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
                            }
                        }
                    }
                    if model.player.meetingId == detail.meeting.id {
                        PlayerBar()
                    }
                }
                Rectangle().fill(Theme.rowSeparator).frame(width: 1)
                Inspector(detail: detail)
                    .frame(width: Theme.inspectorWidth)
            }
        }
        .onKeyPress(.escape) {
            // SwiftUI hands this view key presses meant for an open dropdown too; Escape belongs to the dropdown.
            guard model.overlay == nil, !Dropdown.isOpen else { return .ignored }
            model.goBack()
            return .handled
        }
        .onChange(of: detail.summary?.createdAt, initial: true) { _, written in
            if let written { model.markSummaryRead(detail.meeting.id, written: written) }
        }
        .confirmationDialog("„\(detail.meeting.title)“ löschen?", isPresented: $deleting) {
            Button("Löschen", role: .destructive) { model.deleteMeeting(detail.meeting.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
    }

    private var index: Int? { model.rows.firstIndex { $0.id == detail.meeting.id } }

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(systemName: "chevron.left", label: model.backSection == nil ? String(localized: "Zurück zu den Meetings (Esc)") : String(localized: "Zurück (Esc)")) {
                model.goBack()
            }
            Button((model.backSection ?? .meetings).title) { model.goBack() }
                .buttonStyle(PlainPressStyle())
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text(detail.meeting.title).font(.uiSemibold).lineLimit(1)
            Spacer(minLength: 12)
            if let index {
                Text("\(index + 1) / \(model.rows.count)")
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                IconButton(systemName: "chevron.up", label: String(localized: "Vorheriges Meeting (⌘↑)")) { step(-1) }
                    .disabled(index == 0)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                IconButton(systemName: "chevron.down", label: String(localized: "Nächstes Meeting (⌘↓)")) { step(1) }
                    .disabled(index + 1 >= model.rows.count)
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            Menu {
                Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                    model.copyToClipboard(model.markdown(for: detail), toast: String(localized: "Meeting kopiert", comment: "toast: the whole meeting was copied as Markdown"))
                }
                if detail.summary != nil {
                    Button("Zusammenfassung kopieren", systemImage: "text.quote") {
                        model.copyToClipboard(model.summaryText(for: detail), toast: String(localized: "Zusammenfassung kopiert", comment: "toast"))
                    }
                }
                Button("Als Markdown sichern …", systemImage: "square.and.arrow.down") { model.exportMarkdown(detail) }
            } label: {
                HStack(spacing: 5) {
                    Text("Exportieren")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.smallMedium)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.chipBorder, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(detail.segments.isEmpty)
            .padding(.leading, 6)
            Menu {
                MeetingMenuItems(meetingId: detail.meeting.id) { deleting = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mehr")
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: Theme.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private func step(_ offset: Int) {
        guard let index else { return }
        let target = index + offset
        guard model.rows.indices.contains(target) else { return }
        model.selectedMeetingId = model.rows[target].id
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditableText(text: detail.meeting.title, font: .pageTitle) { model.rename(meetingId: detail.meeting.id, to: $0) }
            Text(metaLine)
                .font(.ui)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 24)
    }

    private var metaLine: String {
        var parts = [TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)]
        if let source = detail.meeting.source { parts.append(source) }
        if detail.meeting.origin == .importedFile { parts.append(String(localized: "Importiert", comment: "the meeting comes from an imported audio file")) }
        return parts.joined(separator: " · ")
    }
}
#endif
