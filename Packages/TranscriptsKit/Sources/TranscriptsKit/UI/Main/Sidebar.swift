import AppKit
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: MeetingRow?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let agenda = model.agenda(now: context.date)
            let waiting = model.inbox.count
            VStack(alignment: .leading, spacing: 2) {
                // Room for the window's traffic lights.
                Color.clear.frame(height: 44)

                HStack(spacing: 6) {
                    RecordButton()
                    SearchButton()
                }
                .padding(.bottom, 12)

                SidebarRow(title: AppModel.Section.inbox.title, systemImage: "tray", active: model.section == .inbox, badge: waiting,
                           badgeHelp: String(localized: "\(waiting) Dinge warten auf dich", comment: "plural: entries in the inbox")) {
                    model.show(.inbox)
                }
                .debugFrame("sidebar.inbox")
                SidebarRow(title: String(localized: "Alle Meetings"), systemImage: "list.bullet.rectangle", active: allMeetingsActive(agenda)) {
                    model.select(nil)
                }
                .debugFrame("sidebar.meetings")
                SidebarRow(title: AppModel.Section.tasks.title, systemImage: "checkmark.circle", active: model.section == .tasks) {
                    model.show(.tasks)
                }
                .debugFrame("sidebar.tasks")

                ScrollView {
                    AgendaList(agenda: agenda, now: context.date) { deleting = $0 }
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.never)

                StatusLine()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .confirmationDialog(
            "„\(deleting?.meeting.title ?? "")“ löschen?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { row in
            Button("Löschen", role: .destructive) { model.deleteMeeting(row.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
    }

    /// The whole list, or a meeting that the day plan doesn't show.
    private func allMeetingsActive(_ agenda: Agenda) -> Bool {
        guard model.section == .meetings else { return false }
        guard let id = model.selectedMeetingId else { return true }
        return !agenda.shows(meetingId: id)
    }
}

/// Search, next to the record button.
struct SearchButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.overlay = .palette
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .help("Suchen (⌘K)")
        .accessibilityLabel("Suchen")
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
    var title: String
    var systemImage: String
    var active = false
    var badge = 0
    var badgeHelp: String?
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
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Theme.control))
                        .help(badgeHelp ?? "")
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
            if meeting.end <= Date() {
                Text("Nicht aufgenommen", comment: "a calendar meeting that is over and was not recorded")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
            } else {
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
            Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.top, 2)
            HStack(spacing: 6) {
                if let title = meeting.calendarTitle {
                    Circle()
                        .fill(meeting.calendarColor.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? Theme.textTertiary)
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    NotMineItems(meeting: meeting, done: close)
                } label: {
                    Text("Nicht mein Meeting").font(.small)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .tint(Theme.textSecondary)
                .accessibilityIdentifier("upcoming.notMine")
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .font(.ui)
        .foregroundStyle(Theme.text)
    }
}

/// "Nicht mein Meeting": hide the series, or everything from its calendar.
struct NotMineItems: View {
    @Environment(AppModel.self) private var model
    var meeting: UpcomingMeeting
    var done: () -> Void = {}

    var body: some View {
        Button(meeting.isRecurring ? String(localized: "Diese Serie ausblenden") : String(localized: "Diesen Termin ausblenden"), systemImage: "eye.slash") {
            done()
            model.hide(.meeting(meeting))
        }
        if let calendar = HiddenCalendarItem.calendar(of: meeting) {
            Button(String(localized: "Alles aus „\(calendar.title)“ ausblenden", comment: "hide every meeting of this calendar"), systemImage: "calendar") {
                done()
                model.hide(calendar)
            }
        }
    }
}

/// The line at the bottom of the sidebar: what the app is doing right now.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            indicator
            Text(text)
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.leading, 8)
            Spacer(minLength: 6)
            Button {
                model.show(.people)
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.section == .people ? Theme.text : Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .hoverFill(active: model.section == .people, radius: 6, fill: model.section == .people ? Theme.selected : Theme.hover)
            }
            .buttonStyle(PlainPressStyle())
            .help("Personen und Stimmen (⌘4)")
            .accessibilityLabel(AppModel.Section.people.title)
            .debugFrame("sidebar.people")
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
