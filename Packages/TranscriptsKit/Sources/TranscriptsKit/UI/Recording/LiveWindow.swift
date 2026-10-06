import SwiftUI

/// The live window: the transcript as it is spoken, and next to it the running summary and markers.
public struct LiveWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        Group {
            if let session = model.recording {
                LiveSessionView(session: session)
            } else {
                finished
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(Theme.panel)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }

    private var finished: some View {
        EmptyState(systemImage: "waveform", title: "Keine Aufnahme", message: "Starte eine Aufnahme mit ⌘R, über die Menüleiste oder aus einer Kalender-Mitteilung.") {
            HStack(spacing: 8) {
                Button("Aufnahme starten") { Task { await model.startRecording() } }
                    .buttonStyle(PrimaryButtonStyle())
                if let id = model.selectedMeetingId, model.row(for: id) != nil {
                    Button("Letztes Meeting öffnen") {
                        model.openMainWindow()
                        dismissWindow(id: "live")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

struct LiveSessionView: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
            if let problem = session.microphoneProblem {
                warning(problem.message, settings: "Privacy_Microphone")
            } else if session.systemAudioSeemsBlocked {
                warning("Vom Call kommt nichts an. Erlaube Transcripts unter Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme.", settings: "Privacy_ScreenCapture")
            }
            HStack(spacing: 0) {
                LiveTranscriptView(session: session)
                Rectangle().fill(Theme.rowSeparator).frame(width: 1)
                LiveSidePane(session: session)
                    .frame(width: 360)
            }
        }
    }

    private func warning(_ text: String, settings pane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(text).font(.small).foregroundStyle(Theme.textBody)
            Spacer(minLength: 8)
            Button("Einstellungen öffnen") { model.openPrivacySettings(pane) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Theme.warning.opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                EditableText(text: session.title, font: .uiSemibold) { session.rename($0) }
                    .lineLimit(1)
                Text(subtitle)
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 320, alignment: .leading)
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if session.state == .paused {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                } else {
                    RecordingDot()
                }
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 13, design: .monospaced))
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Theme.groupHeader))
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                LevelBars(level: session.microphoneLevel)
                if session.capturesSystemAudio {
                    Text(session.source ?? "Call").font(.small).foregroundStyle(Theme.textTertiary).padding(.leading, 6)
                    LevelBars(level: session.systemLevel)
                }
            }
            .help("Pegel von Mikrofon und Call")
            Spacer(minLength: 12)
            Button {
                model.togglePause()
            } label: {
                Label(session.state == .paused ? "Fortsetzen" : "Pause", systemImage: session.state == .paused ? "play.fill" : "pause.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryButtonStyle())
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Beenden", systemImage: "stop.fill")
            }
            .buttonStyle(StopButtonStyle())
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .frame(height: 56)
    }

    private var subtitle: String {
        let voices = session.voices.count
        var parts: [String] = []
        if let source = session.source { parts.append(source) }
        parts.append(voices == 1 ? "1 Stimme" : "\(voices) Stimmen")
        return parts.joined(separator: " · ")
    }
}

struct LiveTranscriptView: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession

    private var items: [LiveLine] {
        session.lines + session.partials.values.sorted { $0.start < $1.start }
    }

    private enum Entry: Identifiable {
        case line(LiveLine)
        case marker(LiveMarker)

        var id: String {
            switch self {
            case .line(let line): line.id
            case .marker(let marker): "marker-\(marker.id)"
            }
        }

        var time: Double {
            switch self {
            case .line(let line): line.start
            case .marker(let marker): marker.time
            }
        }
    }

    /// Lines and markers in the order they happened; the partial line stays last.
    private var entries: [Entry] {
        let finals = (session.lines.map(Entry.line) + session.markers.map(Entry.marker)).sorted { $0.time < $1.time }
        return finals + session.partials.values.sorted { $0.start < $1.start }.map(Entry.line)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if items.isEmpty {
                        waiting
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .line(let line):
                            LiveLineView(session: session, line: line)
                                .id(line.id)
                        case .marker(let marker):
                            MarkerRow(time: marker.time, text: marker.text)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 26)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: items.last?.text) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.engineState == .ready ? "Warte auf Sprache …" : "Die Spracherkennung wird geladen …")
                .font(.uiMedium)
                .foregroundStyle(Theme.textSecondary)
            if case .preparing(let step, let fraction) = model.engineState {
                Text("\(step) · \(Int(fraction * 100)) %").font(.small).foregroundStyle(Theme.textTertiary)
            }
            Text("Das Live-Transkript ist ein Entwurf. Nach dem Meeting wird alles noch einmal genauer transkribiert.")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 8)
    }
}

struct LiveLineView: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession
    let line: LiveLine

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(kind: avatar, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.displayName(for: line.speakerKey)).font(.uiSemibold)
                    Text(TimeFormat.clock(line.start)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                    if line.isPartial {
                        SpeakingIndicator()
                    }
                    if let suggestion = session.voices[line.speakerKey]?.suggestedName, !line.isPartial, isLastLine(of: line.speakerKey) {
                        Button {
                            session.confirm(line.speakerKey, as: suggestion)
                        } label: {
                            Label("Als „\(suggestion)“ speichern", systemImage: "checkmark")
                                .font(.tiny.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .background(Capsule().fill(Theme.selectionFill))
                                .overlay(Capsule().stroke(Theme.selectionBorder, lineWidth: 1))
                        }
                        .buttonStyle(PlainPressStyle())
                        IconButton(systemName: "xmark", label: "Vorschlag verwerfen", size: 20) {
                            session.dismissSuggestion(for: line.speakerKey)
                        }
                    }
                }
                Text(line.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(line.isPartial ? Theme.textSecondary : Theme.textBody)
                    .textSelection(.enabled)
            }
        }
    }

    private func isLastLine(of key: String) -> Bool {
        session.lines.last(where: { $0.speakerKey == key })?.id == line.id
    }

    private var avatar: Avatar.Kind {
        if line.speakerKey == MeetingSpeaker.meKey { return .me(name: model.myName) }
        guard let voice = session.voices[line.speakerKey] else { return .unknown(label: "?") }
        if let name = voice.name { return .person(name: name) }
        return .unknown(label: voice.label)
    }
}

/// Three bars that move while someone is talking.
struct SpeakingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.positive)
                    .frame(width: 2, height: phase ? [5, 10, 7][index] : [9, 4, 10][index])
            }
        }
        .frame(height: 10, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { phase.toggle() }
        }
        .accessibilityLabel("spricht")
    }
}

struct MarkerRow: View {
    var time: Double
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
            Text(TimeFormat.clock(time)).font(.small).monospacedDigit().foregroundStyle(Theme.accent)
            Text(text.isEmpty ? "Markierung" : text).font(.small).foregroundStyle(Theme.textSecondary)
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
        .padding(.leading, 34)
    }
}

struct LiveSidePane: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    summaryHeader
                    summaryContent
                    if !session.markers.isEmpty {
                        Text("Markiert").font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 22)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.markers) { marker in
                                HStack(spacing: 8) {
                                    Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                                    Text(TimeFormat.clock(marker.time)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                                    Text(marker.text.isEmpty ? "Markierung" : marker.text).font(.ui).foregroundStyle(Theme.textBody)
                                    Spacer(minLength: 0)
                                    IconButton(systemName: "xmark", label: "Markierung entfernen", size: 18) { session.removeMarker(marker.id) }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Notiz oder Markierung …", text: $note)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .cardStyle(radius: 8)
                    .focused($noteFocused)
                    .onSubmit(addMarker)
                Text("⏎ setzt eine Markierung an der aktuellen Stelle")
                    .font(.tiny)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
        }
    }

    private func addMarker() {
        session.addMarker(note)
        note = ""
    }

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            Text("Live-Zusammenfassung").font(.uiSemibold)
            Spacer(minLength: 4)
            if model.settings.liveSummary, let summary = model.liveSummary {
                Text(summary.updatedAt, style: .relative)
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
            }
            Toggle("", isOn: Binding(get: { model.settings.liveSummary }, set: { model.setLiveSummary($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!model.summaryProviderReady)
                .help(model.summaryProviderReady ? "Live-Zusammenfassung ein- oder ausschalten" : "Richte zuerst in den Einstellungen ein KI-Modell ein")
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if !model.summaryProviderReady {
            Text("Für eine laufende Zusammenfassung brauchst du ein KI-Modell. Richte es in den Einstellungen unter KI ein.")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 10)
        } else if !model.settings.liveSummary {
            Text("Aus. Eingeschaltet fasst das Modell das Gespräch alle anderthalb Minuten zusammen.")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 10)
        } else if let summary = model.liveSummary {
            VStack(alignment: .leading, spacing: 0) {
                section("Bisher", summary.points)
                section("Aufgaben", summary.actionItems, checkbox: true)
                section("Offen", summary.openQuestions)
            }
        } else if let error = model.liveSummaryError {
            Text(error).font(.small).foregroundStyle(Theme.warning).padding(.top, 10)
        } else {
            Text("Erscheint, sobald genug gesagt wurde.")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String], checkbox: Bool = false) -> some View {
        if !items.isEmpty {
            Text(title).font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 18)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if checkbox {
                            RoundedRectangle(cornerRadius: 3.5).stroke(Theme.textTertiary, lineWidth: 1.4).frame(width: 12, height: 12)
                        } else {
                            Circle().fill(Theme.textTertiary).frame(width: 4, height: 4).offset(y: -2)
                        }
                        Text(item).font(.system(size: 13.5)).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 7)
        }
    }
}
