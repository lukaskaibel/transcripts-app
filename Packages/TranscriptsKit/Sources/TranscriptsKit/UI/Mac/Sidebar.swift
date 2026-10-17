#if os(macOS)
import AppKit
import SwiftUI

/// What the sidebar can select: a section, a recording, or a calendar meeting nobody recorded (which opens a popover).
enum SidebarItem: Hashable {
    case section(AppModel.Section)
    case meeting(String)
    case planned(String)
}

/// The system's sidebar, as in Notebook and Mail: the inbox, all meetings, the tasks and the people, then today's
/// meetings, tomorrow's (folded away) and the ones before today.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: MeetingRow?
    /// The calendar meeting whose popover is open.
    @State private var planned: String?
    @AppStorage("sidebarShowsTomorrow") private var showsTomorrow = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let agenda = model.agenda(now: context.date)
            List(selection: selection(agenda)) {
                Section {
                    Label(AppModel.Section.inbox.title, systemImage: "tray")
                        .badge(model.inbox.count)
                        .help(String(localized: "\(model.inbox.count) Dinge warten auf dich", comment: "plural: entries in the inbox"))
                        .tag(SidebarItem.section(.inbox))
                        .debugFrame("sidebar.inbox")
                    Label(String(localized: "Alle Meetings"), systemImage: "waveform")
                        .tag(SidebarItem.section(.meetings))
                        .debugFrame("sidebar.meetings")
                    Label(AppModel.Section.tasks.title, systemImage: "checkmark.circle")
                        .tag(SidebarItem.section(.tasks))
                        .debugFrame("sidebar.tasks")
                    Label(AppModel.Section.people.title, systemImage: "person.2")
                        .tag(SidebarItem.section(.people))
                        .debugFrame("sidebar.people")
                }

                if !agenda.today.isEmpty || !agenda.tomorrow.isEmpty || model.calendarAllowed == true {
                    Section(String(localized: "Heute")) {
                        if agenda.today.isEmpty {
                            Text("Keine Termine", comment: "sidebar: nothing in the calendar today")
                                .foregroundStyle(.secondary)
                                .selectionDisabled()
                        }
                        ForEach(agenda.today) { item in
                            switch item.kind {
                            case .recorded(let row):
                                RecordedRow(row: row, time: TimeFormat.time(row.meeting.startedAt)) { deleting = row }
                            case .planned(let meeting):
                                PlannedRow(meeting: meeting, now: context.date, popover: $planned)
                            }
                        }
                    }
                }
                if !agenda.tomorrow.isEmpty {
                    Section(isExpanded: $showsTomorrow) {
                        ForEach(agenda.tomorrow) { meeting in
                            PlannedRow(meeting: meeting, now: context.date, popover: $planned)
                        }
                    } header: {
                        Text(String(localized: "Morgen", comment: "sidebar: heading over tomorrow's calendar meetings"))
                            .debugFrame("agenda.tomorrow")
                    }
                }
                if !agenda.recent.isEmpty {
                    Section(String(localized: "Letzte Meetings")) {
                        ForEach(agenda.recent) { row in
                            RecordedRow(row: row, time: TimeFormat.shortDay(row.meeting.startedAt, now: context.date)) { deleting = row }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusLine() }
        .toolbar {
            ToolbarItem { RecordToolbarItem() }
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

    /// The section or the meeting on screen. A meeting the sidebar doesn't list keeps "Alle Meetings" selected.
    private func selection(_ agenda: Agenda) -> Binding<SidebarItem?> {
        Binding {
            switch model.section {
            case .meetings:
                if let id = model.selectedMeetingId, agenda.shows(meetingId: id) { return .meeting(id) }
                return .section(.meetings)
            default:
                return .section(model.section)
            }
        } set: { item in
            switch item {
            case .section(let section): model.show(section)
            case .meeting(let id): model.select(id)
            case .planned(let id): planned = id
            case nil: break
            }
        }
    }
}

/// A recording: its title, and when it was or how far along its processing is.
private struct RecordedRow: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow
    var time: String
    var onDelete: () -> Void

    var body: some View {
        Label {
            Text(row.meeting.title).lineLimit(1)
        } icon: {
            symbol
        }
        .badge(Text(trailing))
        .tag(SidebarItem.meeting(row.id))
        .help("\(row.meeting.title) · \(TimeFormat.duration(row.meeting.duration))")
        .contextMenu { MeetingMenuItems(meetingId: row.id, onDelete: onDelete) }
        .debugFrame("agenda.\(row.id)")
    }

    @ViewBuilder
    private var symbol: some View {
        switch row.meeting.status {
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(Theme.recording)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
        default:
            Image(systemName: "waveform").foregroundStyle(.secondary)
        }
    }

    private var trailing: String {
        switch row.meeting.status {
        case .recording: String(localized: "läuft", comment: "in place of a meeting's duration: it is being recorded right now")
        case .processing: row.meeting.progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current))
        default: time
        }
    }
}

/// A calendar meeting without a recording: greyed, and a click opens its popover to record or join it.
private struct PlannedRow: View {
    var meeting: UpcomingMeeting
    var now: Date
    @Binding var popover: String?

    var body: some View {
        let over = meeting.end <= now
        Label {
            Text(meeting.title).lineLimit(1)
        } icon: {
            Image(systemName: "calendar")
        }
        .foregroundStyle(.secondary)
        .badge(Text(TimeFormat.time(meeting.start)))
        .opacity(over ? 0.6 : 1)
        .tag(SidebarItem.planned(meeting.id))
        .help(over ? String(localized: "Nicht aufgenommen", comment: "a calendar meeting that is over and was not recorded") : meeting.subtitle)
        .contextMenu { NotMineItems(meeting: meeting) }
        .popover(isPresented: Binding(get: { popover == meeting.id }, set: { if !$0 { popover = nil } }), arrowEdge: .trailing) {
            UpcomingPopover(meeting: meeting) { popover = nil }
        }
        .debugFrame("agenda.\(meeting.eventId)")
    }
}

/// In the sidebar's toolbar, where Notebook has its New Note button: start a recording, or the one that runs with
/// its time and a stop button.
struct RecordToolbarItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.recording {
            HStack(spacing: 8) {
                // Plain views and a symbol-only button: the toolbar draws a button with a label of its own as an
                // icon only.
                HStack(spacing: 6) {
                    if session.state == .paused {
                        Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    } else {
                        RecordingDot()
                    }
                    RecordingTime(session: session).monospacedDigit()
                }
                .padding(.leading, 10)
                .contentShape(Rectangle())
                .onTapGesture { model.request(.live) }
                .help("Live-Fenster öffnen")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.request(.live) }
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Aufnahme beenden", systemImage: "stop.circle.fill")
                }
                .foregroundStyle(Theme.recording)
                .help("Aufnahme beenden (⌘R)")
            }
        } else {
            Button {
                Task { await model.startRecording() }
            } label: {
                Label {
                    Text("Aufnehmen")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(Theme.recording)
                }
            }
            .help("Aufnahme starten (⌘R)")
        }
    }
}

/// At the bottom of the sidebar, only while something is going on: processing a meeting, loading the models, or
/// a problem with them. Ready needs no line.
struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if showsStatus {
            HStack(spacing: 8) {
                StatusIndicator()
                Text(model.statusText)
                    .font(.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 30)
            .help(model.statusHelp)
        }
    }

    private var showsStatus: Bool {
        guard model.recording == nil else { return false }
        if model.processingMeetingId != nil { return true }
        switch model.engineState {
        case .preparing, .failed: return true
        default: return !model.modelsDownloaded
        }
    }
}
#endif
