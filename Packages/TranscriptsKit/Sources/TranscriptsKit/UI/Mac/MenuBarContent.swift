#if os(macOS)
import SwiftUI

/// The menu bar icon: a waveform, or a red dot with the running time while recording.
public struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        if let session = model.recording {
            HStack(spacing: 4) {
                Image(systemName: session.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.recording)
                RecordingTime(session: session).monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// What opens from the menu bar, drawn like the system's menus: what is recording (or coming up) at the top, the last
/// meetings, and the way into the app.
public struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.recording {
                recording(session)
            } else {
                upcoming
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
        .frame(width: 290)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }

    private var separator: some View {
        Rectangle().fill(Theme.text.opacity(0.1)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// A title over a couple of lines that say what it is, as the system's menus head a group.
    private func header(_ title: String, _ subtitle: String, dot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.uiSemibold).lineLimit(2)
            HStack(spacing: 6) {
                if dot { RecordingDot(size: 6, pulsing: false) }
                Text(subtitle).font(.small).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 5)
        .padding(.bottom, 5)
    }

    @ViewBuilder
    private var upcoming: some View {
        if let meeting = model.imminentMeeting {
            header(meeting.title, when(meeting))
            MenuRow(title: String(localized: "Aufnahme starten"), symbol: "record.circle", shortcut: "⌘R") {
                Task { await model.startRecording(event: meeting) }
                dismiss()
            }
        } else {
            if let call = model.detector.activeCall {
                header(String(localized: "\(call.appName) nutzt gerade das Mikrofon"), String(localized: "Kein Termin im Kalender", comment: "menu bar: a call without a calendar meeting"))
            }
            MenuRow(title: String(localized: "Aufnahme starten"), symbol: "record.circle", shortcut: "⌘R") {
                Task { await model.startRecording(event: nil) }
                dismiss()
            }
        }
        if let meeting = model.recentlyStoppedMeeting {
            MenuRow(title: String(localized: "\(Strings.quote(meeting.title)) weiter aufnehmen", comment: "menu bar: record the meeting that just ended further; the argument is its title in quotes"), symbol: "arrow.clockwise.circle") {
                Task { await model.resumeRecording(meeting.id) }
                dismiss()
            }
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
    private func recording(_ session: RecordingSession) -> some View {
        let state = session.state == .paused ? String(localized: "Pausiert") : String(localized: "Aufnahme läuft")
        header(session.title, "\(state) · \(TimeFormat.clock(session.elapsed))", dot: session.state != .paused)
        MenuRow(title: session.state == .paused ? String(localized: "Fortsetzen") : String(localized: "Pausieren"), shortcut: "⇧⌘P") {
            model.togglePause()
        }
        MenuRow(title: String(localized: "Aufnahme beenden"), shortcut: "⌘R") {
            Task { await model.stopRecording() }
            dismiss()
        }
        MenuRow(title: String(localized: "Markierung setzen"), shortcut: "⇧⌘M") {
            session.addMarker("")
        }
        separator
        MenuRow(title: String(localized: "Live-Transkript"), shortcut: "⌘L") {
            model.request(.live)
            dismiss()
        }
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
            Text("Noch keine Meetings").foregroundStyle(Theme.textSecondary).padding(.horizontal, 9).frame(height: 24)
        }
        ForEach(rows) { row in
            MenuRow(title: row.meeting.title, detail: TimeFormat.shortDay(row.meeting.startedAt)) {
                model.select(row.id)
                model.openMainWindow()
                dismiss()
            }
        }
    }
}

/// A line of the menu: the accent behind it and white text under the pointer, as in the system's menus.
private struct MenuRow: View {
    var title: String
    var symbol: String? = nil
    var detail: String? = nil
    var shortcut: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(hovering ? .white : Theme.recording)
                        .frame(width: 16)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 10)
                if let detail {
                    Text(detail).foregroundStyle(hovering ? .white.opacity(0.85) : Theme.textSecondary)
                }
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.85) : Theme.textTertiary)
                }
            }
            .foregroundStyle(hovering ? .white : Theme.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.accentFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
