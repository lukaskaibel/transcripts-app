import SwiftUI

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
        Button("Zusammenfassung kopieren", systemImage: "text.quote") { model.copySummary(of: meetingId) }
            .disabled(row?.hasSummary != true)
        Button("Aufgaben kopieren", systemImage: "checklist") { model.copyTasks(of: meetingId) }
            .disabled(row?.actionItems.isEmpty != false)
        Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
            if let detail = try? model.database.detail(of: meetingId) {
                model.copyToClipboard(model.markdown(for: detail), toast: String(localized: "Meeting kopiert", comment: "toast: the whole meeting was copied as Markdown"))
            }
        }
        .disabled(!ready)
        #if os(macOS)
        Button("Exportieren …", systemImage: "square.and.arrow.up") {
            if let detail = try? model.database.detail(of: meetingId) { model.exportMarkdown(detail) }
        }
        .disabled(!ready)
        Button("Aufnahme im Finder zeigen", systemImage: "folder") { model.revealAudio(meetingId) }
        #else
        if ready, let row {
            ShareLink(item: MeetingExport(meetingId: meetingId, title: row.meeting.title, model: model),
                      preview: SharePreview(row.meeting.title)) {
                Label("Exportieren …", systemImage: "square.and.arrow.up")
            }
        }
        #endif
        Divider()
        Button("Löschen …", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(row?.meeting.status == .recording)
    }
}

#if os(iOS)
import UniformTypeIdentifiers

/// A meeting as Markdown for the share sheet, written when it is shared rather than when a menu is built.
struct MeetingExport: Transferable {
    let meetingId: String
    let title: String
    let model: AppModel

    @MainActor
    private func markdown() -> String? {
        (try? model.database.detail(of: meetingId)).map { model.markdown(for: $0) }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { export in
            guard let text = await export.markdown() else { throw CocoaError(.fileReadNoSuchFile) }
            let name = export.title.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "Meeting" : name).appendingPathExtension("md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .utf8PlainText) { export in
            Data((await export.markdown() ?? "").utf8)
        }
    }
}
#endif
