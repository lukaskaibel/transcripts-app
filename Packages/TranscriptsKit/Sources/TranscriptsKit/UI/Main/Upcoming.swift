import SwiftUI

/// A calendar meeting that hasn't been recorded: who is invited, and the buttons to record or join it. The Mac
/// shows it in a popover from the day plan, iPhone and iPad in a sheet.
struct UpcomingPopover: View {
    @Environment(AppModel.self) private var model
    var meeting: UpcomingMeeting
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(Platform.isMobile ? .title3.weight(.semibold) : .system(size: 14, weight: .semibold))
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
                            Platform.open(url)
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
        #if os(macOS)
        .frame(width: 280, alignment: .leading)
        #endif
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
