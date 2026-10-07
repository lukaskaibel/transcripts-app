import AppKit
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 44)

            RecordButton()
                .padding(.bottom, 12)

            SidebarRow(title: "Suchen", systemImage: "magnifyingglass", trailing: "⌘K") {
                model.overlay = .palette
            }
            SidebarRow(title: "Meetings", systemImage: "list.bullet.rectangle", active: model.section == .meetings) {
                model.section = .meetings
                model.selectedMeetingId = nil
            }
            SidebarRow(title: "Personen", systemImage: "person.2", active: model.section == .people, badge: model.pendingVoiceCount) {
                model.section = .people
            }

            if !model.nextMeetings.isEmpty {
                Text("Anstehend")
                    .font(.tinySemibold)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.nextMeetings.prefix(3)) { meeting in
                        UpcomingRow(meeting: meeting)
                    }
                }
            }

            Spacer(minLength: 8)
            StatusLine()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// The big button at the top: start a recording, or show the one that is running.
struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.recording {
            HStack(spacing: 8) {
                Button {
                    model.request(.live)
                } label: {
                    HStack(spacing: 9) {
                        RecordingDot()
                        Text(TimeFormat.clock(session.elapsed)).font(.uiMedium).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help("Live-Fenster öffnen")
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Aufnahme beenden (⌘R)")
                .accessibilityLabel("Aufnahme beenden")
                .padding(.trailing, 4)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.recording.opacity(0.45), lineWidth: 1))
        } else {
            Button {
                Task { await model.startRecording() }
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(Theme.recording).frame(width: 9, height: 9).padding(.horizontal, 2)
                    Text("Aufnehmen").font(.uiMedium)
                    Spacer(minLength: 0)
                    Text("⌘R").font(.small).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .help("Aufnahme starten")
        }
    }
}

struct SidebarRow: View {
    var title: LocalizedStringKey
    var systemImage: String
    var active = false
    var trailing: String?
    var badge = 0
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.small).foregroundStyle(Theme.textTertiary)
                }
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Theme.control))
                        .help(String(localized: "\(badge) Stimmen warten auf dich", comment: "plural: voices waiting for the user to name them"))
                }
            }
            .font(active ? .uiMedium : .ui)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .hoverFill(active: active, radius: 7, fill: active ? Theme.selected : Theme.hover)
        }
        .buttonStyle(PlainPressStyle())
    }
}

struct UpcomingRow: View {
    @Environment(AppModel.self) private var model
    var meeting: UpcomingMeeting
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(meeting.isRunning ? Theme.recording : Theme.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text(when)
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .hoverFill(radius: 7)
        }
        .buttonStyle(PlainPressStyle())
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            UpcomingPopover(meeting: meeting) { showing = false }
        }
    }

    private var when: String {
        let day = TimeFormat.dayTitle(meeting.start)
        var text = meeting.isRunning ? String(localized: "Läuft · seit \(TimeFormat.time(meeting.start))", comment: "a calendar meeting is running, since this time of day") : "\(day), \(TimeFormat.time(meeting.start))"
        if let app = meeting.app { text += " · \(app)" }
        return text
    }
}

struct UpcomingPopover: View {
    @Environment(AppModel.self) private var model
    var meeting: UpcomingMeeting
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.system(size: 14, weight: .semibold))
                Text("\(TimeFormat.dayTitle(meeting.start)), \(TimeFormat.time(meeting.start))–\(TimeFormat.time(meeting.end))\(meeting.app.map { " · \($0)" } ?? "")")
                    .font(.small)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !meeting.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meeting.attendees.prefix(8), id: \.self) { attendee in
                        HStack(spacing: 8) {
                            Avatar(kind: .person(name: attendee.name), size: 18)
                            Text(attendee.name).lineLimit(1)
                        }
                    }
                    if meeting.attendees.count > 8 {
                        Text(String(localized: "und \(meeting.attendees.count - 8) weitere", comment: "plural: more attendees than the list shows")).font(.small).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    close()
                    Task { await model.startRecording(event: meeting) }
                } label: {
                    Label("Aufnehmen", systemImage: "record.circle")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isRecording)
                if let url = meeting.joinURL {
                    Button("Beitreten") {
                        close()
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .font(.ui)
        .foregroundStyle(Theme.text)
    }
}

/// The line at the bottom of the sidebar: what the app is doing right now.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(text)
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(systemName: "slider.horizontal.3", label: String(localized: "Einstellungen (⌘,)"), size: 24) {
                openSettings()
            }
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .help(help)
    }

    @ViewBuilder
    private var indicator: some View {
        if model.recording != nil {
            RecordingDot(size: 7)
        } else if model.processingMeetingId != nil {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else {
            switch model.engineState {
            case .preparing:
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            case .failed:
                Circle().fill(Theme.warning).frame(width: 7, height: 7)
            default:
                Circle().fill(model.modelsDownloaded ? Theme.positive : Theme.warning).frame(width: 7, height: 7)
            }
        }
    }

    private var text: String {
        if model.recording != nil { return String(localized: "Aufnahme läuft") }
        if let id = model.processingMeetingId, let row = model.row(for: id) {
            return String(localized: "Wird verarbeitet · \(row.meeting.progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))")
        }
        switch model.engineState {
        case .preparing(_, let fraction): return String(localized: "Modelle werden geladen · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))")
        case .failed: return String(localized: "Modelle fehlen")
        default: return model.modelsDownloaded ? String(localized: "Bereit · alles lokal") : String(localized: "Modelle noch nicht geladen")
        }
    }

    private var help: String {
        switch model.engineState {
        case .failed(let message): return message
        case .preparing(let step, _): return String(localized: "\(step) wird geladen", comment: "%@ is the part being loaded, e.g. Spracherkennung")
        default: return String(localized: "Spracherkennung und Stimmerkennung laufen auf diesem Mac.")
        }
    }
}
