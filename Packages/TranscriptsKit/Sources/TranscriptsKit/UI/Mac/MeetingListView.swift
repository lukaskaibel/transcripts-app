#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var deleting: MeetingRow?

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle(AppModel.Section.meetings.title)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button {
                    importing = true
                } label: {
                    Label("Audiodatei importieren …", systemImage: "square.and.arrow.down")
                }
                .help("Audiodatei importieren …")
            }
            ToolbarSpacer(.fixed)
            SearchToolbarItem(model: model)
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

    var body: some View {
        Button {
            model.select(row.id)
        } label: {
            HStack(spacing: 12) {
                symbol
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.meeting.title)
                        .font(.uiMedium)
                        .lineLimit(1)
                    if let note {
                        Text(note)
                            .font(.small)
                            .foregroundStyle(row.meeting.status == .failed ? Theme.warning : Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(row.meeting.status == .recording ? String(localized: "läuft", comment: "in place of a meeting's duration: it is being recorded right now") : TimeFormat.duration(row.meeting.duration))
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                Text(TimeFormat.time(row.meeting.startedAt))
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .contextMenu {
            MeetingMenuItems(meetingId: row.id, onDelete: onDelete)
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch row.meeting.status {
        case .recording: Image(systemName: "record.circle").foregroundStyle(Theme.recording)
        case .processing: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        case .ready: Image(systemName: "waveform").foregroundStyle(row.hasSummary ? Theme.accent : Theme.textTertiary)
        }
    }

    /// What is special about the meeting, under its title: the step it is in, an error, or voices without a name.
    private var note: String? {
        switch row.meeting.status {
        case .processing: row.meeting.processingStep ?? String(localized: "Wird verarbeitet")
        case .failed: String(localized: "Fehler bei der Verarbeitung")
        case .ready where row.pendingVoices > 0: String(localized: "\(row.pendingVoices) Stimmen offen", comment: "plural: voices in a meeting still waiting for a name")
        default: nil
        }
    }
}
#endif
