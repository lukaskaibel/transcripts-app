import SwiftUI

/// ⌘K: commands, meetings by title, and full-text search through every transcript.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var highlighted = 0
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        enum Kind { case command, meeting, hit, person }
        var id: String
        var kind: Kind
        var title: String
        var detail: String?
        var systemImage: String?
        var shortcut: String?
        var action: () -> Void
    }

    private var entries: [Entry] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [Entry] = []
        let commands: [Entry] = [
            model.isRecording
                ? Entry(id: "stop", kind: .command, title: String(localized: "Aufnahme beenden"), systemImage: "stop.circle", shortcut: "⌘R") { Task { await model.stopRecording() } }
                : Entry(id: "record", kind: .command, title: String(localized: "Aufnahme starten"), systemImage: "record.circle", shortcut: "⌘R") { Task { await model.startRecording() } },
            Entry(id: "live", kind: .command, title: String(localized: "Live-Fenster öffnen"), systemImage: "waveform", shortcut: "⌘L") { model.request(.live) },
            Entry(id: "inbox", kind: .command, title: AppModel.Section.inbox.title, systemImage: "tray", shortcut: "⌘1") { model.show(.inbox) },
            Entry(id: "meetings", kind: .command, title: String(localized: "Alle Meetings"), systemImage: "list.bullet.rectangle", shortcut: "⌘2") { model.select(nil) },
            Entry(id: "tasks", kind: .command, title: AppModel.Section.tasks.title, systemImage: "checkmark.circle", shortcut: "⌘3") { model.show(.tasks) },
            Entry(id: "people", kind: .command, title: AppModel.Section.people.title, systemImage: "person.2", shortcut: "⌘4") { model.show(.people) },
            Entry(id: "settings", kind: .command, title: String(localized: "Einstellungen"), systemImage: "slider.horizontal.3", shortcut: "⌘,") { openSettings() },
        ]
        result += commands.filter { text.isEmpty || $0.title.lowercased().contains(text) }
        let meetings = model.rows.filter { text.isEmpty || $0.meeting.title.lowercased().contains(text) }.prefix(text.isEmpty ? 6 : 8)
        result += meetings.map { row in
            Entry(id: "m-\(row.id)", kind: .meeting, title: row.meeting.title, detail: "\(TimeFormat.dayTitle(row.meeting.startedAt)), \(TimeFormat.time(row.meeting.startedAt))", systemImage: "doc.text") {
                model.focusedSegmentId = nil
                model.select(row.id)
            }
        }
        if !text.isEmpty {
            result += model.people.filter { $0.name.lowercased().contains(text) }.prefix(4).map { person in
                Entry(id: "p-\(person.id)", kind: .person, title: person.name, detail: String(localized: "Person"), systemImage: "person") { model.show(.people) }
            }
            result += hits.map { hit in
                Entry(id: "h-\(hit.id)", kind: .hit, title: hit.snippet, detail: "\(hit.meetingTitle) · \(TimeFormat.clock(hit.segment.start))", systemImage: "text.magnifyingglass") {
                    model.select(hit.segment.meetingId)
                    model.focusedSegmentId = hit.segment.id
                }
            }
        }
        return result
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Suche in Meetings und Transkripten, oder ein Befehl …", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(entries) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(entries.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onExitCommand { model.overlay = nil }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if entries.isEmpty {
                            Text("Nichts gefunden").foregroundStyle(Theme.textTertiary).padding(14)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || entries[index - 1].kind != entry.kind {
                                Text(sectionTitle(entry.kind))
                                    .font(.tinySemibold)
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 4 : 10)
                                    .padding(.bottom, 2)
                            }
                            Button {
                                highlighted = index
                                run(entries)
                            } label: {
                                row(entry, active: index == highlighted)
                            }
                            .buttonStyle(PlainPressStyle())
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
                .onChange(of: highlighted) { _, index in
                    if entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                }
            }
        }
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 30, y: 16)
        .onAppear { focused = true }
        .onChange(of: query) { _, text in
            highlighted = 0
            hits = (try? model.database.search(text, limit: 20)) ?? []
        }
    }

    private func sectionTitle(_ kind: Entry.Kind) -> String {
        switch kind {
        case .command: String(localized: "Befehle")
        case .meeting: String(localized: "Meetings")
        case .person: String(localized: "Personen")
        case .hit: String(localized: "Im Transkript", comment: "command palette section: lines found in transcripts")
        }
    }

    private func row(_ entry: Entry, active: Bool) -> some View {
        HStack(spacing: 10) {
            if let image = entry.systemImage {
                Image(systemName: image).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedSnippet(entry.title)).lineLimit(entry.kind == .hit ? 2 : 1)
                if let detail = entry.detail {
                    Text(detail).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut { Keycap(shortcut) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(active ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }

    /// Search snippets mark the match with «»; show it in the accent colour instead.
    private func highlightedSnippet(_ text: String) -> AttributedString {
        guard text.contains("«") else { return AttributedString(text) }
        var result = AttributedString()
        var inMatch = false
        var current = ""
        for character in text {
            if character == "«" || character == "»" {
                var piece = AttributedString(current)
                if inMatch {
                    piece.foregroundColor = Theme.accent
                    piece.font = .uiSemibold
                }
                result += piece
                current = ""
                inMatch = character == "«"
            } else {
                current.append(character)
            }
        }
        result += AttributedString(current)
        return result
    }

    private func run(_ entries: [Entry]) {
        guard entries.indices.contains(highlighted) else { return }
        model.overlay = nil
        entries[highlighted].action()
    }
}
