import AppKit
import SwiftUI

/// The sidebar under the navigation: today as a day plan with a line for now, tomorrow folded away, and the
/// meetings before today.
struct AgendaList: View {
    @Environment(AppModel.self) private var model
    var agenda: Agenda
    var now: Date
    var onDelete: (MeetingRow) -> Void
    @State private var showsTomorrow = false

    var body: some View {
        let timeWidth = Self.timeWidth
        VStack(alignment: .leading, spacing: 0) {
            if !agenda.today.isEmpty || !agenda.tomorrow.isEmpty || model.calendarAllowed == true {
                SidebarHeading(title: String(localized: "Heute"))
                if agenda.today.isEmpty {
                    Text("Keine Termine", comment: "sidebar: nothing in the calendar today")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                } else {
                    today(timeWidth: timeWidth)
                }
                if !agenda.tomorrow.isEmpty {
                    tomorrow(timeWidth: timeWidth)
                }
            }
            if !agenda.recent.isEmpty {
                SidebarHeading(title: String(localized: "Letzte Meetings"))
                ForEach(agenda.recent) { row in
                    RecordedLine(row: row, time: TimeFormat.shortDay(row.meeting.startedAt, now: now), timeWidth: timeWidth, axis: [], showsVoices: false, onDelete: onDelete)
                }
            }
        }
    }

    @ViewBuilder
    private func today(timeWidth: CGFloat) -> some View {
        let items = agenda.today
        let started = agenda.started(by: now)
        let next = agenda.next(now: now)
        // The day's line runs through every item and the line for now, which goes after what has started.
        let nodes = items.count + 1
        let axis = { (place: Int) -> AgendaAxis in
            var axis: AgendaAxis = []
            if place > 0 { axis.insert(.above) }
            if place < nodes - 1 { axis.insert(.below) }
            return axis
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index == started {
                NowLine(now: now, timeWidth: timeWidth, axis: axis(started))
            }
            let place = index < started ? index : index + 1
            switch item.kind {
            case .recorded(let row):
                RecordedLine(row: row, time: TimeFormat.time(row.meeting.startedAt), timeWidth: timeWidth, axis: axis(place), onDelete: onDelete)
            case .planned(let meeting):
                PlannedLine(meeting: meeting, now: now, timeWidth: timeWidth, axis: axis(place), isNext: meeting.id == next?.id)
            }
        }
        if started == items.count {
            NowLine(now: now, timeWidth: timeWidth, axis: axis(started))
        }
    }

    @ViewBuilder
    private func tomorrow(timeWidth: CGFloat) -> some View {
        Button {
            withAnimation(Theme.quick) { showsTomorrow.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(String(localized: "Morgen · \(agenda.tomorrow.count) Termine", comment: "plural: sidebar, how many calendar meetings tomorrow has"))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showsTomorrow ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(.small)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .hoverFill(radius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .debugFrame("agenda.tomorrow")
        if showsTomorrow {
            ForEach(agenda.tomorrow) { meeting in
                PlannedLine(meeting: meeting, now: now, timeWidth: timeWidth, axis: [], isNext: false)
            }
        }
    }

    /// Wide enough for every time of day and every weekday in the interface's language.
    static var timeWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let samples = [10, 12, 22, 23].compactMap { calendar.date(bySettingHour: $0, minute: 58, second: 0, of: day) }.map(TimeFormat.time)
            + (1...6).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }.map { TimeFormat.shortDay($0) }
        let widest = samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 34
        return ceil(widest) + 2
    }
}

struct SidebarHeading: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.tinySemibold)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 18)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Which way the day's line runs from a glyph.
struct AgendaAxis: OptionSet {
    let rawValue: Int
    static let above = AgendaAxis(rawValue: 1)
    static let below = AgendaAxis(rawValue: 2)
}

/// One line of the day plan: the time, a glyph on the day's line, the title, and what is special about it.
private struct AgendaLine<Glyph: View, Trailing: View>: View {
    enum Look { case plain, selected, next }

    var time: String
    var timeWidth: CGFloat
    var axis: AgendaAxis
    var look: Look = .plain
    var title: String
    /// A second line, for the meeting to get ready for.
    var subtitle: String?
    @ViewBuilder var glyph: Glyph
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(time)
                .font(.small)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(width: timeWidth, alignment: .leading)
            VStack(spacing: 0) {
                AxisSegment(visible: axis.contains(.above))
                glyph.frame(width: 14, height: 14).padding(.vertical, 2)
                AxisSegment(visible: axis.contains(.below))
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(look == .plain ? .ui : .uiMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: subtitle == nil ? 28 : 42)
        .background {
            if look == .next {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
            }
        }
        .hoverFill(active: look == .selected, radius: 7, fill: look == .selected ? Theme.selected : Theme.hover)
        .contentShape(Rectangle())
    }
}

private struct AxisSegment: View {
    var visible: Bool

    var body: some View {
        Rectangle()
            .fill(visible ? Theme.barOff : .clear)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

/// Where the day stands: a quiet grey line between what has started and what is still to come.
private struct NowLine: View {
    var now: Date
    var timeWidth: CGFloat
    var axis: AgendaAxis

    var body: some View {
        HStack(spacing: 8) {
            Text(TimeFormat.time(now))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: timeWidth, alignment: .leading)
            VStack(spacing: 0) {
                AxisSegment(visible: axis.contains(.above))
                Circle().fill(Theme.textSecondary).frame(width: 5, height: 5)
                AxisSegment(visible: axis.contains(.below))
            }
            .frame(width: 14)
            Rectangle().fill(Theme.textTertiary.opacity(0.45)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Jetzt, \(TimeFormat.time(now))", comment: "sidebar: the line that marks the current time"))
    }
}

/// A recording in the day plan or under "Letzte Meetings": opens the meeting.
struct RecordedLine: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow
    var time: String
    var timeWidth: CGFloat
    var axis: AgendaAxis
    /// A dot for voices without a name: today only, the inbox has the rest.
    var showsVoices = true
    var onDelete: (MeetingRow) -> Void

    var body: some View {
        let selected = model.section == .meetings && model.selectedMeetingId == row.id
        Button {
            model.select(row.id)
        } label: {
            AgendaLine(time: time, timeWidth: timeWidth, axis: axis, look: selected ? .selected : .plain, title: row.meeting.title) {
                MeetingGlyph(state: row.glyph)
            } trailing: {
                trailing
            }
        }
        .buttonStyle(PlainPressStyle())
        .help("\(row.meeting.title) · \(TimeFormat.duration(row.meeting.duration))")
        .contextMenu { MeetingMenuItems(meetingId: row.id) { onDelete(row) } }
        .debugFrame("agenda.\(row.id)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.meeting.status {
        case .recording:
            Text(String(localized: "läuft", comment: "in place of a meeting's duration: it is being recorded right now"))
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
        case .processing:
            Text(row.meeting.progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))
                .font(.small)
                .monospacedDigit()
                .foregroundStyle(Theme.warning)
        case .ready where showsVoices && row.pendingVoices > 0:
            Circle()
                .fill(Theme.warning)
                .frame(width: 6, height: 6)
                .help(String(localized: "\(row.pendingVoices) Stimmen offen", comment: "plural: voices in a meeting still waiting for a name"))
        default:
            EmptyView()
        }
    }
}

/// A calendar meeting without a recording: its popover records or joins it.
private struct PlannedLine: View {
    var meeting: UpcomingMeeting
    var now: Date
    var timeWidth: CGFloat
    var axis: AgendaAxis
    var isNext: Bool
    @State private var showing = false

    var body: some View {
        let over = meeting.end <= now
        Button {
            showing = true
        } label: {
            AgendaLine(time: TimeFormat.time(meeting.start), timeWidth: timeWidth, axis: axis, look: isNext ? .next : .plain, title: meeting.title,
                       subtitle: isNext ? ([TimeFormat.relative(to: meeting.start, now: now)] + [meeting.app].compactMap { $0 }).joined(separator: " · ") : nil) {
                MeetingGlyph(state: .upcoming)
            } trailing: {
                EmptyView()
            }
            .opacity(over ? 0.5 : 1)
        }
        .buttonStyle(PlainPressStyle())
        .help(over ? String(localized: "Nicht aufgenommen", comment: "a calendar meeting that is over and was not recorded") : meeting.subtitle)
        .contextMenu { NotMineItems(meeting: meeting) }
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            UpcomingPopover(meeting: meeting) { showing = false }
        }
        .debugFrame("agenda.\(meeting.eventId)")
    }
}
