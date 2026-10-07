import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var deleting: MeetingRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AppModel.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importAudio(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.selectionFill.opacity(0.5))
                    .overlay(Text("Audiodatei hier ablegen zum Transkribieren").font(.uiMedium).foregroundStyle(Theme.accent))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "„\(deleting?.meeting.title ?? "")“ löschen?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { row in
            Button("Löschen", role: .destructive) { model.deleteMeeting(row.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Meetings").font(.uiSemibold)
            Text("\(model.rows.count)").foregroundStyle(Theme.textTertiary)
            Spacer()
            IconButton(systemName: "square.and.arrow.down", label: String(localized: "Audiodatei importieren …")) { importing = true }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: Theme.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private var emptyState: some View {
        EmptyState(systemImage: "waveform", title: String(localized: "Noch keine Meetings"), message: String(localized: "Starte eine Aufnahme mit ⌘R oder über die Menüleiste. Du kannst auch eine Audiodatei hierher ziehen.")) {
            HStack(spacing: 8) {
                Button("Aufnahme starten") { Task { await model.startRecording() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Datei importieren …") { importing = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(Array(model.groupedRows.enumerated()), id: \.offset) { index, group in
                    SectionHeader(title: group.title, count: group.rows.count)
                        .padding(.top, index == 0 ? 0 : 10)
                        .padding(.bottom, 2)
                    ForEach(group.rows) { row in
                        MeetingRowView(row: row, onDelete: { deleting = row })
                    }
                }
            }
            .padding(10)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importAudio([url]) }
            }
        }
    }
}

struct MeetingRowView: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow
    var onDelete: () -> Void
    @State private var hovering = false

    private var peopleById: [String: Person] {
        Dictionary(uniqueKeysWithValues: model.people.map { ($0.id, $0) })
    }

    var body: some View {
        Button {
            model.select(row.id)
        } label: {
            HStack(spacing: 12) {
                MeetingGlyph(state: row.glyph)
                    .frame(width: 16)
                Text(row.meeting.title)
                    .font(.uiMedium)
                    .lineLimit(1)
                if row.pendingVoices > 0, row.meeting.status == .ready {
                    DotChip(text: String(localized: "\(row.pendingVoices) Stimmen offen", comment: "plural: voices in a meeting still waiting for a name"), color: Theme.warning)
                }
                if row.meeting.status == .processing {
                    Text(row.meeting.processingStep ?? String(localized: "Wird verarbeitet"))
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if row.meeting.status == .failed {
                    Text("Fehler bei der Verarbeitung").font(.small).foregroundStyle(Theme.warning)
                }
                Spacer(minLength: 12)
                AvatarStack(kinds: row.avatarKinds(people: peopleById), ring: hovering ? Theme.hover : Theme.panel)
                Text(row.meeting.status == .recording ? String(localized: "läuft", comment: "in place of a meeting's duration: it is being recorded right now") : TimeFormat.duration(row.meeting.duration))
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 76, alignment: .trailing)
                Text(TimeFormat.time(row.meeting.startedAt))
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .contextMenu {
            MeetingMenuItems(meetingId: row.id, onDelete: onDelete)
        }
    }
}

/// The actions on a meeting, shared by the list's context menu and the detail's "more" menu.
struct MeetingMenuItems: View {
    @Environment(AppModel.self) private var model
    var meetingId: String
    var onDelete: () -> Void

    var body: some View {
        let row = model.row(for: meetingId)
        let ready = row?.meeting.status == .ready
        Button("Zusammenfassung erstellen", systemImage: "sparkle") {
            Task { await model.generateSummary(meetingId) }
        }
        .disabled(!ready || !model.summaryProviderReady || model.isSummarizing(meetingId))
        Button("Neu transkribieren", systemImage: "arrow.clockwise") { model.reprocess(meetingId) }
            .disabled(row?.meeting.status == .recording || model.processingMeetingId == meetingId)
        Divider()
        Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
            if let detail = try? model.database.detail(of: meetingId) {
                model.copyToClipboard(model.markdown(for: detail), what: String(localized: "Meeting"))
            }
        }
        .disabled(!ready)
        Button("Exportieren …", systemImage: "square.and.arrow.up") {
            if let detail = try? model.database.detail(of: meetingId) { model.exportMarkdown(detail) }
        }
        .disabled(!ready)
        Button("Aufnahme im Finder zeigen", systemImage: "folder") { model.revealAudio(meetingId) }
        Divider()
        Button("Löschen …", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(row?.meeting.status == .recording)
    }
}
