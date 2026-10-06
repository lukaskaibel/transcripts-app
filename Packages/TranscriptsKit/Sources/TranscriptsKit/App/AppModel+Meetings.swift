import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    public func rename(meetingId: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? database.update(meetingId: meetingId) { meeting in
            meeting.title = trimmed
            meeting.titleIsCustom = true
        }
    }

    /// Deletes a meeting with its transcript, summary and audio.
    public func deleteMeeting(_ meetingId: String) {
        if recording?.meetingId == meetingId { return }
        if selectedMeetingId == meetingId {
            // Step to a neighbour so the list keeps its place.
            let ids = rows.map(\.id)
            if let index = ids.firstIndex(of: meetingId) {
                selectedMeetingId = index + 1 < ids.count ? ids[index + 1] : (index > 0 ? ids[index - 1] : nil)
            }
        }
        player.stop()
        try? database.deleteMeeting(meetingId)
        try? FileManager.default.removeItem(at: AppPaths.folder(for: meetingId))
    }

    public static let importableTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie, .mpeg4Movie, .quickTimeMovie]

    /// Brings in recordings made elsewhere (voice memos, Zoom recordings) and transcribes them.
    public func importAudio(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let meeting = Meeting(
                title: url.deletingPathExtension().lastPathComponent,
                titleIsCustom: false,
                startedAt: created,
                status: .processing,
                origin: .importedFile,
                processingStep: "Wird importiert"
            )
            do {
                try FileManager.default.createDirectory(at: AppPaths.folder(for: meeting.id), withIntermediateDirectories: true)
                let target = AppPaths.importedFile(for: meeting.id, extension: url.pathExtension.lowercased().nonEmpty ?? "m4a")
                try FileManager.default.copyItem(at: url, to: target)
                var meeting = meeting
                meeting.duration = SpeechAudio.duration(of: target)
                try database.save(meeting)
                if meeting.duration == 0 {
                    // A video or a format AVAudioFile can't read: pull the audio out first.
                    Task { await extractAudioAndProcess(meeting.id, from: target) }
                } else {
                    enqueueProcessing(meeting.id)
                }
            } catch {
                showToast("„\(url.lastPathComponent)“ ließ sich nicht importieren", error.localizedDescription, isError: true)
            }
        }
        if let first = urls.first, let row = rows.first(where: { $0.meeting.title == first.deletingPathExtension().lastPathComponent }) {
            select(row.id)
        }
    }

    private func extractAudioAndProcess(_ meetingId: String, from source: URL) async {
        let target = AppPaths.importedFile(for: meetingId, extension: "m4a")
        let asset = AVURLAsset(url: source)
        do {
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let temporary = target.deletingLastPathComponent().appendingPathComponent("extracted.m4a")
            try await export.export(to: temporary, as: .m4a)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: temporary, to: target)
            let duration = SpeechAudio.duration(of: target)
            try database.update(meetingId: meetingId) { $0.duration = duration }
            enqueueProcessing(meetingId)
        } catch {
            try? database.update(meetingId: meetingId) { meeting in
                meeting.status = .failed
                meeting.errorMessage = "Die Datei enthält kein lesbares Audio."
            }
        }
    }

    // MARK: Export

    public func markdown(for detail: MeetingDetail) -> String {
        var lines: [String] = ["# \(detail.meeting.title)", ""]
        var meta = TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)
        if let source = detail.meeting.source { meta += " · \(source)" }
        lines.append(meta)
        let names = detail.speakers.map { detail.displayName(for: $0.key) == Strings.me ? myName : detail.displayName(for: $0.key) }
        if !names.isEmpty { lines.append("Teilnehmer: " + names.joined(separator: ", ")) }
        if let summary = detail.summary {
            lines += ["", "## Zusammenfassung", "", summary.overview]
            if !summary.decisions.isEmpty {
                lines += ["", "### Entscheidungen", ""] + summary.decisions.map { "- \($0)" }
            }
            if !detail.actionItems.isEmpty {
                lines += ["", "### Aufgaben", ""] + detail.actionItems.map { item in
                    let extra = [item.owner, item.due].compactMap { $0 }.joined(separator: ", ")
                    return "- [\(item.done ? "x" : " ")] \(item.text)\(extra.isEmpty ? "" : " (\(extra))")"
                }
            }
            if !summary.openQuestions.isEmpty {
                lines += ["", "### Offene Fragen", ""] + summary.openQuestions.map { "- \($0)" }
            }
        }
        if !detail.markers.isEmpty {
            lines += ["", "## Markierungen", ""] + detail.markers.map { "- \(TimeFormat.clock($0.time)) \($0.text.isEmpty ? "Markierung" : $0.text)" }
        }
        if !detail.segments.isEmpty {
            lines += ["", "## Transkript", ""]
            for segment in detail.segments {
                let name = segment.speakerKey == MeetingSpeaker.meKey ? myName : detail.displayName(for: segment.speakerKey)
                lines.append("**\(name)** (\(TimeFormat.clock(segment.start))): \(segment.text)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func summaryText(for detail: MeetingDetail) -> String {
        guard let summary = detail.summary else { return "" }
        var lines = [summary.overview]
        if !summary.decisions.isEmpty { lines += ["", "Entscheidungen:"] + summary.decisions.map { "• \($0)" } }
        if !detail.actionItems.isEmpty {
            lines += ["", "Aufgaben:"] + detail.actionItems.map { item in
                let extra = [item.owner, item.due].compactMap { $0 }.joined(separator: ", ")
                return "• \(item.text)\(extra.isEmpty ? "" : " (\(extra))")"
            }
        }
        if !summary.openQuestions.isEmpty { lines += ["", "Offene Fragen:"] + summary.openQuestions.map { "• \($0)" } }
        return lines.joined(separator: "\n")
    }

    public func copyToClipboard(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("\(what) kopiert")
    }

    public func exportMarkdown(_ detail: MeetingDetail) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = detail.meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown(for: detail).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showToast("Export fehlgeschlagen", error.localizedDescription, isError: true)
        }
    }

    public func revealAudio(_ meetingId: String) {
        let folder = AppPaths.folder(for: meetingId)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            showToast("Keine Aufnahme vorhanden")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
