import SwiftUI

#if os(macOS)
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
    @AppStorage("liveShowsSummary") private var showsSummary = false

    var body: some View {
        VStack(spacing: 0) {
            if let problem = session.microphoneProblem {
                warning(problem.message, settings: "Privacy_Microphone")
            } else if session.systemAudioSeemsBlocked {
                warning(String(localized: "Vom Call kommt nichts an. Erlaube Transcripts unter Datenschutz & Sicherheit → Aufnahme von Bildschirm & Systemaudio."), settings: "Privacy_ScreenCapture")
            }
            header
            Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.top, 16)
            LiveTranscriptView(session: session)
        }
        .overlay(alignment: .bottom) {
            controls.padding(.bottom, 22)
        }
        .inspector(isPresented: $showsSummary) {
            LiveSidePane(session: session)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
        .navigationTitle(session.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Toggle(isOn: $showsSummary) {
                    Label("Live-Zusammenfassung", systemImage: "sparkle")
                }
                .help("Live-Zusammenfassung und Markierungen")
            }
            ToolbarItem {
                Menu {
                    Button("Umbenennen …", systemImage: "pencil") {
                        NamePrompt.ask(title: String(localized: "Umbenennen"), message: "", initial: session.title) { session.rename($0) }
                    }
                    Button("Markierung setzen", systemImage: "bookmark") { session.addMarker("") }
                } label: {
                    Label("Mehr", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.12)))
        .padding(.horizontal, 28)
        .padding(.top, 10)
    }

    /// The time, large, the sound of the last seconds, and where it comes from.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if session.state == .paused {
                    Image(systemName: "pause.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textSecondary)
                } else {
                    RecordingDot(size: 11)
                }
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 38, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(session.state == .paused ? Theme.textSecondary : Theme.text)
                    .contentTransition(.numericText())
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Label("Mikrofon", systemImage: "mic").labelStyle(.titleAndIcon)
                    LevelBars(level: session.microphoneLevel, color: Theme.positive, height: 12)
                    if session.capturesSystemAudio {
                        Label(session.source ?? String(localized: "Call", comment: "label of the level meter for the call's sound"), systemImage: "video")
                            .labelStyle(.titleAndIcon)
                            .padding(.leading, 10)
                        LevelBars(level: session.systemLevel, color: Theme.positive, height: 12)
                    }
                }
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .help("Pegel von Mikrofon und Call")
            }
            LevelWaveform(level: { session.waveformLevel() }, bars: 160, height: 54, running: session.state != .paused)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .clipped()
        }
        .padding(.horizontal, 40)
        .padding(.top, 14)
    }

    /// Pause, stop and a bookmark, floating over the transcript as Voice Memos has them.
    private var controls: some View {
        HStack(spacing: 18) {
            Button {
                model.togglePause()
            } label: {
                Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.text.opacity(0.07)))
            }
            .buttonStyle(PlainPressStyle())
            .help(session.state == .paused ? "Fortsetzen (⇧⌘P)" : "Pausieren (⇧⌘P)")
            .accessibilityLabel(session.state == .paused ? "Fortsetzen" : "Pausieren")
            Button {
                Task { await model.stopRecording() }
            } label: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.recordingFill)
                    .frame(width: 20, height: 20)
                    .frame(width: 52, height: 52)
                    .background(Circle().strokeBorder(Theme.textTertiary.opacity(0.35), lineWidth: 3))
            }
            .buttonStyle(PlainPressStyle())
            .help("Aufnahme beenden (⌘R)")
            .accessibilityLabel("Aufnahme beenden")
            Button {
                session.addMarker("")
            } label: {
                Image(systemName: "bookmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.text.opacity(0.07)))
            }
            .buttonStyle(PlainPressStyle())
            .help("Markierung setzen (⇧⌘M)")
            .accessibilityLabel("Markierung setzen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let source = session.source { parts.append(source) }
        parts.append(session.state == .paused ? String(localized: "Pausiert", comment: "the recording is paused") : String(localized: "Aufnahme läuft"))
        return parts.joined(separator: " · ")
    }
}

#endif

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
                            LiveMarkerRow(marker: marker)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Platform.isMobile ? 20 : 40)
                .padding(.top, Platform.isMobile ? 18 : 22)
                .padding(.bottom, Platform.isMobile ? 18 : 110)
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
                Text("\(step) · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))").font(.small).foregroundStyle(Theme.textTertiary)
            }
            Text("Das Live-Transkript ist ein Entwurf. Nach dem Meeting wird alles noch einmal genauer transkribiert.")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 8)
    }
}

/// A line as it is spoken: when, and what. Nobody's name: who is talking is only guessed during the meeting and
/// settled afterwards. Only your own lines say so, where the call comes in on its own and the microphone is yours.
struct LiveLineView: View {
    let session: RecordingSession
    let line: LiveLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if !Platform.isMobile {
                VStack(alignment: .leading, spacing: 1) {
                    Text(TimeFormat.clock(line.start))
                        .font(.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    if isYou {
                        Text(Strings.me).font(.tinySemibold).foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 56, alignment: .leading)
            }
            Text(line.text)
                .font(.live)
                .lineSpacing(4)
                .foregroundStyle(line.isPartial ? Theme.textSecondary : Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isYou: Bool {
        session.capturesSystemAudio && line.speakerKey == MeetingSpeaker.meKey
    }
}

/// A bookmark in the live transcript, in the time column's line.
private struct LiveMarkerRow: View {
    let marker: LiveMarker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if !Platform.isMobile {
                Text(TimeFormat.clock(marker.time))
                    .font(.small)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .leading)
            }
            Label(marker.text.isEmpty ? String(localized: "Markierung", comment: "a marker set at a moment of the recording, without a note") : marker.text, systemImage: "bookmark.fill")
                .font(.uiMedium)
        }
        .foregroundStyle(Theme.accent)
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
        .accessibilityLabel(String(localized: "spricht", comment: "accessibility: someone is talking right now"))
    }
}

struct MarkerRow: View {
    var time: Double
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill").font(.system(size: 10))
            Text(TimeFormat.clock(time)).font(.small).monospacedDigit()
            Text(text.isEmpty ? String(localized: "Markierung", comment: "a marker set at a moment of the recording, without a note") : text).font(.uiMedium)
                .layoutPriority(1)
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
        .foregroundStyle(Theme.accent)
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
                        Text(String(localized: "Markiert", comment: "heading: the markers set during the recording")).font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 22)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(session.markers) { marker in
                                HStack(spacing: 8) {
                                    Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                                    Text(TimeFormat.clock(marker.time)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                                    Text(marker.text.isEmpty ? String(localized: "Markierung", comment: "a marker set at a moment of the recording, without a note") : marker.text).font(.ui).foregroundStyle(Theme.textBody)
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
                    .submitLabel(.done)
                    .padding(.horizontal, 12)
                    .frame(height: Platform.isMobile ? 44 : 34)
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
                section(String(localized: "Bisher", comment: "heading in the live summary: what was said so far"), summary.points)
                section(String(localized: "Aufgaben", comment: "heading in the live summary: action items"), summary.actionItems, checkbox: true)
                section(String(localized: "Offen", comment: "heading in the live summary: open questions"), summary.openQuestions)
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
                        Text(item).font(Platform.isMobile ? .ui : .system(size: 13.5)).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 7)
        }
    }
}
