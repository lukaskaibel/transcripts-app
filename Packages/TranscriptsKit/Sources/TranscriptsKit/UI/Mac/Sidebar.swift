#if os(macOS)
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

    private var indicator: some View {
        StatusIndicator()
    }

    private var text: String {
        model.statusText
    }

    private var help: String {
        model.statusHelp
    }
}
#endif
