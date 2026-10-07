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
                Text(TimeFormat.clock(session.elapsed)).monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

/// What opens from the menu bar: the next meeting with a record button, recent meetings, and the way in.
public struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = model.recording {
                recordingCard(session)
            } else {
                nextMeetingCard
            }
            divider
            recent
            divider
            VStack(spacing: 0) {
                menuRow("Alle Meetings öffnen", shortcut: "⌘O") {
                    model.openMainWindow()
                    dismiss()
                }
                menuRow("Einstellungen …", shortcut: "⌘,") {
                    NSApp.activate()
                    openSettings()
                    dismiss()
                }
                menuRow("Transcripts beenden", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 300)
        .font(.ui)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
    }

    private var divider: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1)
    }

    @ViewBuilder
    private var nextMeetingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let meeting = model.imminentMeeting {
                Label {
                    Text(when(meeting))
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).padding(.top, 4)
                if !meeting.attendees.isEmpty {
                    HStack(spacing: 8) {
                        AvatarStack(kinds: meeting.attendees.map { .person(name: $0.name) }, size: 18, limit: 3, ring: Theme.popover)
                        Text(meeting.subtitle.replacingOccurrences(of: (meeting.app ?? "") + " · ", with: ""))
                            .font(.small)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 8)
                }
                recordButton(event: meeting).padding(.top, 12)
            } else if let call = model.detector.activeCall {
                Label("\(call.appName) nutzt gerade das Mikrofon", systemImage: "phone")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                recordButton(event: nil).padding(.top, 12)
            } else {
                Text("Kein Meeting in Sicht").font(.uiMedium)
                Text("Anstehende Termine aus deinem Kalender erscheinen hier.")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                recordButton(event: nil).padding(.top, 12)
            }
        }
        .padding(14)
    }

    /// "Beginnt in 5 Min. · Zoom".
    private func when(_ meeting: UpcomingMeeting) -> String {
        let relative = TimeFormat.relative(to: meeting.start)
        let when = meeting.start > Date()
            ? String(localized: "Beginnt \(relative)", comment: "a meeting starts; the argument is like “in 5 min.” or “now”")
            : String(localized: "Läuft \(relative)", comment: "a meeting is running; the argument is like “for 3 min.” or “now”")
        return ([when] + [meeting.app].compactMap { $0 }).joined(separator: " · ")
    }

    private func recordButton(event: UpcomingMeeting?) -> some View {
        Button {
            Task { await model.startRecording(event: event) }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.recording).frame(width: 8, height: 8)
                Text("Aufnahme starten").font(.uiMedium)
                Spacer()
                Text("⌘R").font(.small).opacity(0.6)
            }
            .foregroundStyle(Theme.panel)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.text))
        }
        .buttonStyle(PlainPressStyle())
    }

    private func recordingCard(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RecordingDot()
                Text(session.state == .paused ? "Pausiert" : "Aufnahme läuft").font(.small).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(TimeFormat.clock(session.elapsed)).font(.system(size: 13, design: .monospaced)).monospacedDigit()
            }
            Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).padding(.top, 6)
            HStack(spacing: 8) {
                Button {
                    model.request(.live)
                    dismiss()
                } label: {
                    Text("Live-Transkript").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(session.state == .paused ? "Fortsetzen" : "Pausieren")
                Button {
                    Task { await model.stopRecording() }
                    dismiss()
                } label: {
                    Label(String(localized: "Beenden", comment: "button: stop the recording"), systemImage: "stop.fill")
                }
                .buttonStyle(StopButtonStyle())
            }
            .padding(.top, 12)
        }
        .padding(14)
    }

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Letzte Meetings").font(.tinySemibold).foregroundStyle(Theme.textTertiary).padding(.horizontal, 8).padding(.vertical, 4)
            let rows = Array(model.rows.filter { $0.meeting.status != .recording }.prefix(3))
            if rows.isEmpty {
                Text("Noch keine Meetings").font(.small).foregroundStyle(Theme.textTertiary).padding(.horizontal, 8).frame(height: 28)
            }
            ForEach(rows) { row in
                Button {
                    model.select(row.id)
                    model.openMainWindow()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        MeetingGlyph(state: row.glyph, size: 13)
                        Text(row.meeting.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(TimeFormat.shortDay(row.meeting.startedAt)).font(.small).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .hoverFill(radius: 6)
                }
                .buttonStyle(PlainPressStyle())
            }
        }
        .padding(6)
    }

    private func menuRow(_ title: LocalizedStringKey, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).font(.small).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .hoverFill(radius: 6)
        }
        .buttonStyle(PlainPressStyle())
    }
}
