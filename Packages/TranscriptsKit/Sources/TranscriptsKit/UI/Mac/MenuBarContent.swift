#if os(macOS)
import SwiftUI

/// The menu bar icon: a waveform; while recording a red dot with the running time, or a warning sign while no sound
/// comes in. It is the only thing on screen that says a recording runs, so a problem shows here too.
public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        if let session = model.recording {
            HStack(spacing: 4) {
                if session.soundProblem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, Theme.warning)
                } else {
                    Image(systemName: session.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.recording)
                }
                RecordingTime(session: session).monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

extension RecordingSession {
    /// What is wrong with the sound, if anything, and the pane of the privacy settings that fixes it.
    var soundProblem: (text: String, pane: String)? {
        if let problem = microphoneProblem { return (problem.shortMessage, "Privacy_Microphone") }
        if systemAudioSeemsBlocked { return (String(localized: "Vom Call kommt nichts an"), "Privacy_ScreenCapture") }
        return nil
    }
}

/// What opens from the menu bar. On top the recording, with the time, the sound, the last words and big buttons for
/// pause, stop and a marker; without one a button that starts it. Below that the last meetings and the way into the
/// app, as rows like the system's menus have.
public struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.recording {
                MenuBarRecorder(session: session) { dismiss() }
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                separator
                MenuRow(title: String(localized: "Live-Transkript"), symbol: "text.quote", shortcut: "⌘L") {
                    model.request(.live)
                    dismiss()
                }
            } else {
                start
            }
            separator
            recent
            separator
            MenuRow(title: String(localized: "Alle Meetings öffnen"), shortcut: "⌘O") {
                model.openMainWindow()
                dismiss()
            }
            MenuRow(title: String(localized: "Einstellungen …"), shortcut: "⌘,") {
                NSApp.activate()
                openSettings()
                dismiss()
            }
            MenuRow(title: String(localized: "Transcripts beenden"), shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(5)
        .frame(width: 300)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }

    private var separator: some View {
        Rectangle().fill(Theme.text.opacity(0.1)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// The meeting coming up, or the call that has the microphone, over one big button that starts the recording.
    @ViewBuilder
    private var start: some View {
        let meeting = model.imminentMeeting
        VStack(alignment: .leading, spacing: 10) {
            if let meeting {
                heading(meeting.title, when(meeting))
            } else if let call = model.detector.activeCall {
                heading(String(localized: "\(call.appName) nutzt gerade das Mikrofon"), String(localized: "Kein Termin im Kalender", comment: "menu bar: a call without a calendar meeting"))
            }
            Button {
                Task { await model.startRecording(event: meeting) }
                dismiss()
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Text("Aufnahme starten").lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuBarButtonStyle(fill: Theme.recordingFill, foreground: .white))
            .help("Aufnahme starten (⌘R)")
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, model.recentlyStoppedMeeting == nil ? 8 : 4)
        if let meeting = model.recentlyStoppedMeeting {
            MenuRow(title: String(localized: "\(Strings.quote(meeting.title)) weiter aufnehmen", comment: "menu bar: record the meeting that just ended further; the argument is its title in quotes"), symbol: "arrow.clockwise") {
                Task { await model.resumeRecording(meeting.id) }
                dismiss()
            }
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            Text(subtitle).font(.small).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
        }
    }

    /// "Beginnt in 5 Min. · Zoom".
    private func when(_ meeting: UpcomingMeeting) -> String {
        let relative = TimeFormat.relative(to: meeting.start)
        let when = meeting.start > Date()
            ? String(localized: "Beginnt \(relative)", comment: "a meeting starts; the argument is like “in 5 min.” or “now”")
            : String(localized: "Läuft \(relative)", comment: "a meeting is running; the argument is like “for 3 min.” or “now”")
        return ([when] + [meeting.app].compactMap { $0 }).joined(separator: " · ")
    }

    @ViewBuilder
    private var recent: some View {
        Text("Letzte Meetings")
            .font(.tinySemibold)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
        let rows = Array(model.rows.filter { $0.meeting.status != .recording }.prefix(3))
        if rows.isEmpty {
            Text("Noch keine Meetings").foregroundStyle(Theme.textSecondary).padding(.horizontal, 9).frame(height: 26)
        }
        ForEach(rows) { row in
            MenuRow(title: row.meeting.title, glyph: row.glyph, detail: TimeFormat.shortDay(row.meeting.startedAt)) {
                model.select(row.id)
                model.openMainWindow()
                dismiss()
            }
        }
    }
}

/// The running recording at the top of the menu. Its parts keep their size whatever happens, so the menu doesn't
/// change size while it is open: only the time, the sound and the words in it change.
private struct MenuBarRecorder: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession
    var close: () -> Void
    /// Set for a moment after a marker was set, so the click shows it worked.
    @State private var markedAt: Date?

    var body: some View {
        let paused = session.state == .paused
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if paused {
                        Image(systemName: "pause.fill").font(.system(size: 8, weight: .black))
                    } else {
                        RecordingDot(size: 7)
                    }
                    Text(([paused ? String(localized: "Pausiert", comment: "the recording is paused") : String(localized: "Aufnahme läuft")] + [session.source].compactMap { $0 }).joined(separator: " · "))
                        .lineLimit(1)
                }
                .font(.tinySemibold)
                .foregroundStyle(paused ? Theme.textSecondary : Theme.recording)
                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
            }
            HStack(alignment: .center, spacing: 12) {
                RecordingTime(session: session)
                    .font(.system(size: 28, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(paused ? Theme.textSecondary : Theme.text)
                Spacer(minLength: 0)
                LevelWaveform(level: { session.waveformLevel() }, bars: 24, height: 26, running: !paused)
            }
            news
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
            controls(paused: paused)
        }
    }

    /// What there is to know right now: a problem with the sound and how to fix it, the marker just set, or the last
    /// words heard, without a name (who is talking is settled after the meeting).
    @ViewBuilder
    private var news: some View {
        if let problem = session.soundProblem {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(problem.text).font(.small).foregroundStyle(Theme.text).lineLimit(2)
                Spacer(minLength: 4)
                Button(String(localized: "Beheben …", comment: "menu bar: opens the privacy settings that block the sound")) {
                    model.openPrivacySettings(problem.pane)
                    close()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.14)))
        } else if markedAt != nil {
            Label(String(localized: "Markierung gesetzt", comment: "menu bar: shown for a moment after the marker button was clicked"), systemImage: "bookmark.fill")
                .font(.smallMedium)
                .foregroundStyle(Theme.accent)
                .transition(.opacity)
        } else if let line = session.partials.values.max(by: { $0.start < $1.start }) ?? session.lines.last {
            Text(Self.ending(of: line.text))
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.head)
        } else {
            Text(model.engineState == .ready ? "Warte auf Sprache …" : "Spracherkennung wird geladen …")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// The end of a line, as much as two lines hold: the newest words matter, not how the sentence began. Text cut at
    /// the head keeps only the start of a text over more than one line.
    static func ending(of text: String) -> String {
        guard text.count > 80 else { return text }
        let tail = text.suffix(80)
        let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "… " + tail[start...]
    }

    /// Pause, stop and a marker, as in the live window: stop in the middle and the widest, since it is what's wanted
    /// most and can't be missed.
    private func controls(paused: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(MenuBarButtonStyle(round: true))
            .help(paused ? "Fortsetzen (⇧⌘P)" : "Pausieren (⇧⌘P)")
            .accessibilityLabel(paused ? "Fortsetzen" : "Pausieren")
            Button {
                Task { await model.stopRecording() }
                close()
            } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 9, height: 9)
                    Text("Aufnahme beenden").lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuBarButtonStyle(fill: Theme.recordingFill, foreground: .white))
            .help("Aufnahme beenden (⌘R)")
            Button {
                session.addMarker("")
                let now = Date()
                withAnimation(Theme.quick) { markedAt = now }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if markedAt == now { withAnimation(Theme.quick) { markedAt = nil } }
                }
            } label: {
                Image(systemName: markedAt == nil ? "bookmark" : "bookmark.fill")
                    .foregroundStyle(markedAt == nil ? Theme.text : Theme.accent)
            }
            .buttonStyle(MenuBarButtonStyle(round: true))
            .help("Markierung setzen (⇧⌘M)")
            .accessibilityLabel("Markierung setzen")
        }
    }
}

/// The menu's big buttons: a capsule, or a circle for an icon alone, a little lighter under the pointer.
private struct MenuBarButtonStyle: ButtonStyle {
    var fill = Theme.text.opacity(0.08)
    var foreground = Theme.text
    var round = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, style: self)
    }

    private struct Styled: View {
        let configuration: Configuration
        let style: MenuBarButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(style.foreground)
                .padding(.horizontal, style.round ? 0 : 12)
                .frame(minWidth: 32, minHeight: 32)
                .background(Capsule().fill(style.fill))
                .overlay(Capsule().fill(Theme.text.opacity(hovering ? 0.06 : 0)))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.quick, value: hovering)
        }
    }
}

/// A line of the menu, lit up softly under the pointer.
private struct MenuRow: View {
    var title: String
    var symbol: String? = nil
    var glyph: MeetingGlyph.State? = nil
    var detail: String? = nil
    var shortcut: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                } else if let glyph {
                    MeetingGlyph(state: glyph, size: 12).frame(width: 16)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 10)
                if let detail {
                    Text(detail).foregroundStyle(Theme.textSecondary)
                }
                if let shortcut {
                    Text(shortcut).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .hoverFill(fill: Theme.text.opacity(0.08))
    }
}
#endif
