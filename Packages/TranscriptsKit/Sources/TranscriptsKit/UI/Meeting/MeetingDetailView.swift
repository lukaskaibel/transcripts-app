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
            guard model.overlay == nil else { return .ignored }
            model.selectedMeetingId = nil
            return .handled
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
            IconButton(systemName: "chevron.left", label: "Zurück zu den Meetings (Esc)") {
                model.selectedMeetingId = nil
            }
            Button("Meetings") { model.selectedMeetingId = nil }
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
                IconButton(systemName: "chevron.up", label: "Vorheriges Meeting (⌘↑)") { step(-1) }
                    .disabled(index == 0)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                IconButton(systemName: "chevron.down", label: "Nächstes Meeting (⌘↓)") { step(1) }
                    .disabled(index + 1 >= model.rows.count)
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            Menu {
                Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                    model.copyToClipboard(model.markdown(for: detail), what: "Meeting")
                }
                if detail.summary != nil {
                    Button("Zusammenfassung kopieren", systemImage: "text.quote") {
                        model.copyToClipboard(model.summaryText(for: detail), what: "Zusammenfassung")
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
        if detail.meeting.origin == .importedFile { parts.append("Importiert") }
        return parts.joined(separator: " · ")
    }
}

/// Recording, processing or failed: what the meeting is waiting for.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    var body: some View {
        switch detail.meeting.status {
        case .recording:
            banner {
                RecordingDot()
                Text("Aufnahme läuft").font(.uiMedium)
                Text("Das Transkript unten ist vorläufig.").foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Live-Fenster") { model.request(.live) }.buttonStyle(SecondaryButtonStyle())
            }
        case .processing:
            banner {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.meeting.processingStep ?? "Wird verarbeitet").font(.uiMedium)
                    ThinBar(fraction: detail.meeting.progress)
                        .frame(maxWidth: 260)
                }
                Spacer()
                Text("\(Int(detail.meeting.progress * 100)) %").font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
        case .failed:
            banner {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verarbeitung fehlgeschlagen").font(.uiMedium)
                    if let message = detail.meeting.errorMessage {
                        Text(message).font(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Erneut versuchen") { model.reprocess(detail.meeting.id) }.buttonStyle(SecondaryButtonStyle())
            }
        case .ready:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle()
            .padding(.bottom, 24)
    }
}

/// "2 Stimmen ohne Namen": the way into naming them, one after another.
struct VoicesBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    private var open: [MeetingSpeaker] {
        detail.speakers.filter { $0.needsReview && $0.talkTime >= 4 }
    }

    var body: some View {
        let open = open
        if detail.meeting.status == .ready, !open.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "person.wave.2").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(open.count == 1 ? "Eine Stimme ohne Namen" : "\(open.count) Stimmen ohne Namen").font(.uiMedium)
                    Text(hint(open)).font(.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button("Wer ist das?") { model.startNaming(detail.meeting.id) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle()
            .padding(.bottom, 24)
        }
    }

    private func hint(_ open: [MeetingSpeaker]) -> String {
        let guessed = open.filter { !detail.guesses(for: $0).isEmpty || $0.suggestedName != nil }
        guard !guessed.isEmpty else { return "Anhören und benennen, dann erkennt die App sie wieder." }
        return guessed.map { detail.displayName(for: $0.key) }.joined(separator: " · ")
    }
}

struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(PlainPressStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            IconButton(systemName: "gobackward.15", label: "15 Sekunden zurück") { player.skip(-15) }
            IconButton(systemName: "goforward.15", label: "15 Sekunden vor") { player.skip(15) }
            Text(TimeFormat.clock(player.currentTime)).font(.small).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { player.currentTime }, set: { value in Task { await player.seek(to: value) } }), in: 0...max(player.duration, 1))
                .controlSize(.small)
            Text(TimeFormat.clock(player.duration)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
            IconButton(systemName: "xmark", label: "Wiedergabe schließen", size: 22) { player.stop() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }
}
