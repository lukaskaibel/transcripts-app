import AVFoundation
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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

    // MARK: Joining

    /// Whether a meeting can be joined with others: one this device recorded, finished, whose audio is still here,
    /// while nothing is being recorded.
    public func canJoin(_ meeting: Meeting) -> Bool {
        recording == nil && !joiningMeetings && meeting.origin == .recording && (meeting.status == .ready || meeting.status == .failed)
            && AppPaths.existingAudio(for: meeting.id, channel: .microphone) != nil
    }

    /// The meetings of that day a meeting can be joined with, itself among them, in the order they were recorded;
    /// none if there is no other.
    public func joinCandidates(for meetingId: String) -> [Meeting] {
        guard let meeting = row(for: meetingId)?.meeting, canJoin(meeting) else { return [] }
        let candidates = rows.map(\.meeting)
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: meeting.startedAt) && canJoin($0) }
            .sorted { $0.startedAt < $1.startedAt }
        return candidates.count > 1 ? candidates : []
    }

    /// The candidates that look like parts of the same meeting: recorded right before or after it.
    public func likelyParts(of meetingId: String) -> Set<String> {
        guard let meeting = row(for: meetingId)?.meeting else { return [] }
        return Set(MeetingJoin.parts(of: meeting, among: joinCandidates(for: meetingId)))
    }

    /// Joins meetings recorded one after another into the first of them, and transcribes it again: the later ones'
    /// audio goes after its own, with their lines, names, markers and tasks, and the later ones are deleted. Returns
    /// the meetings joined, the one they are in now first; nil if they weren't.
    @discardableResult
    public func joinMeetings(_ meetingIds: Set<String>) async -> [String]? {
        let meetings = rows.map(\.meeting).filter { meetingIds.contains($0.id) && canJoin($0) }.sorted { $0.startedAt < $1.startedAt }
        guard meetings.count > 1, let first = meetings.first else { return nil }
        guard meetings.count == meetingIds.count else {
            showToast(String(localized: "Meetings ließen sich nicht zusammenführen"), MeetingJoin.Failure.changed.localizedDescription, isError: true)
            return nil
        }
        joiningMeetings = true
        defer { joiningMeetings = false }
        let ids = meetings.map(\.id)
        let hadSummary = ids.contains { row(for: $0)?.hasSummary == true }
        if let playing = player.meetingId, ids.contains(playing) { player.stop() }
        // Recording files of a pass that just finished may still be being compressed.
        for id in ids { await finishingAudio[id]?.value }
        let database = database
        let step = String(localized: "Wartet", comment: "processing step: waiting in line to be transcribed")
        do {
            _ = try await Task.detached(priority: .userInitiated) { try MeetingJoin.join(ids, database: database, step: step) }.value
        } catch {
            showToast(String(localized: "Meetings ließen sich nicht zusammenführen"), error.localizedDescription, isError: true)
            return nil
        }
        if let selected = selectedMeetingId, ids.dropFirst().contains(selected) { selectedMeetingId = first.id }
        if hadSummary { summarizeAfterPass.insert(first.id) }
        enqueueProcessing(first.id)
        showToast(String(localized: "\(ids.count) Meetings zusammengeführt", comment: "plural: toast, how many meetings were joined into one"), String(localized: "Das Meeting wird neu transkribiert."))
        return ids
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
                processingStep: String(localized: "Wird importiert")
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
                showToast(String(localized: "\(Strings.quote(url.lastPathComponent)) ließ sich nicht importieren", comment: "toast: a file name in quotes"), error.localizedDescription, isError: true)
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
                meeting.errorMessage = String(localized: "Die Datei enthält kein lesbares Audio.")
            }
        }
    }

    // MARK: Export

    public func markdown(for detail: MeetingDetail) -> String {
        var lines: [String] = ["# \(detail.meeting.title)", ""]
        var meta = TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)
        if let source = detail.meeting.source { meta += " · \(source)" }
        lines.append(meta)
        let names = detail.speakers.map { $0.isMe ? myName : detail.textName(for: $0.key) }
        if !names.isEmpty { lines.append(String(localized: "Teilnehmer: \(names.joined(separator: ", "))")) }
        if let summary = detail.summary {
            lines += ["", "## " + String(localized: "Zusammenfassung"), "", SummaryText.sections(summary, tasks: detail.actionItems, level: 3)]
        }
        if !detail.markers.isEmpty {
            lines += ["", "## " + String(localized: "Markierungen", comment: "markers set during a recording"), ""] + detail.markers.map { "- \(TimeFormat.clock($0.time)) \($0.text.isEmpty ? String(localized: "Markierung", comment: "a marker set during a recording, without a text") : $0.text)" }
        }
        if !detail.segments.isEmpty {
            lines += ["", "## " + String(localized: "Transkript"), ""]
            for segment in detail.segments {
                let name = segment.speakerKey == MeetingSpeaker.meKey ? myName : detail.textName(for: segment.speakerKey)
                lines.append("**\(name)** (\(TimeFormat.clock(segment.start))): \(segment.text)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Puts `text` on the clipboard and says so with `toast` ("Zusammenfassung kopiert").
    public func copyToClipboard(_ text: String, toast: String) {
        Platform.copy(text)
        showToast(toast)
    }

    /// The meeting's summary as Markdown, for pasting into a chat, a ticket or a note.
    public func copySummary(of meetingId: String) {
        guard let detail = try? database.detail(of: meetingId), detail.summary != nil else { return }
        copyToClipboard(SummaryText.markdown(detail), toast: String(localized: "Zusammenfassung kopiert", comment: "toast"))
    }

    /// The meeting's tasks as a Markdown checklist.
    public func copyTasks(of meetingId: String) {
        guard let detail = try? database.detail(of: meetingId), !detail.actionItems.isEmpty else { return }
        copyToClipboard(SummaryText.tasks(detail.actionItems), toast: String(localized: "Aufgaben kopiert", comment: "toast"))
    }

    #if os(macOS)
    public func exportMarkdown(_ detail: MeetingDetail) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = detail.meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown(for: detail).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showToast(String(localized: "Export fehlgeschlagen"), error.localizedDescription, isError: true)
        }
    }

    public func revealAudio(_ meetingId: String) {
        let folder = AppPaths.folder(for: meetingId)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            showToast(String(localized: "Keine Aufnahme vorhanden"))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    #endif
}
