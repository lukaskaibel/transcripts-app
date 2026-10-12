#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The meetings: today as a day plan with a line for now, as in the Mac's sidebar, then every meeting before,
/// grouped by day. A tap opens a meeting (beside the list on a wide iPad); a planned one offers to record it.
struct MeetingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide
    @State private var importing = false
    @State private var deleting: MeetingRow?
    @State private var showsTomorrow = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let agenda = model.agenda(now: context.date)
            Group {
                if model.rows.isEmpty && agenda.today.isEmpty && agenda.tomorrow.isEmpty {
                    empty
                } else {
                    list(agenda: agenda, now: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .navigationTitle(AppModel.Section.meetings.title)
        .navigationSubtitle(model.statusText)
        .toolbar {
            SettingsToolbarItem()
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    importing = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(Text("Audiodatei importieren …"))
                .accessibilityIdentifier("import")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AppModel.importableTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importAudio(urls) }
        }
        .confirmationDialog(
            "„\(deleting?.meeting.title ?? "")“ löschen?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { row in
            Button("Löschen", role: .destructive) {
                navigation.forget(meeting: row.id)
                model.deleteMeeting(row.id)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
    }

    private var empty: some View {
        MobileEmptyState(
            systemImage: "waveform",
            title: String(localized: "Noch keine Meetings"),
            message: String(localized: "Leg das \(Platform.deviceName) in die Mitte des Tisches und tippe auf „Aufnehmen“. Du kannst auch eine Aufnahme aus Dateien oder Sprachmemos importieren.", comment: "iPhone or iPad")
        ) {
            VStack(spacing: 10) {
                Button("Aufnahme starten") { Task { await model.startRecording() } }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Datei importieren …") { importing = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func list(agenda: Agenda, now: Date) -> some View {
        let older = model.groupedRows.filter { group in
            group.rows.first.map { !Calendar.current.isDate($0.meeting.startedAt, inSameDayAs: now) } ?? false
        }
        return List {
            if !agenda.today.isEmpty || !agenda.tomorrow.isEmpty || model.calendarAllowed == true {
                Section {
                    today(agenda: agenda, now: now)
                    if !agenda.tomorrow.isEmpty {
                        tomorrow(agenda: agenda, now: now)
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Heute"))
                }
            }
            ForEach(Array(older.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.rows) { row in
                        meetingRow(row)
                    }
                } header: {
                    MobileSectionHeader(title: group.title, count: group.rows.count)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.bottom, 12, for: .scrollContent)
    }

    // MARK: Today

    @ViewBuilder
    private func today(agenda: Agenda, now: Date) -> some View {
        let items = agenda.today
        if items.isEmpty {
            Text("Keine Termine", comment: "sidebar: nothing in the calendar today")
                .font(.ui)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Theme.panel)
                .listRowSeparator(.hidden)
        } else {
            let started = agenda.started(by: now)
            let next = agenda.next(now: now)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == started {
                    MobileNowLine(now: now)
                }
                switch item.kind {
                case .recorded(let row):
                    meetingRow(row)
                case .planned(let meeting):
                    plannedRow(meeting, now: now, isNext: meeting.id == next?.id)
                }
            }
            if started == items.count {
                MobileNowLine(now: now)
            }
        }
    }

    @ViewBuilder
    private func tomorrow(agenda: Agenda, now: Date) -> some View {
        Button {
            withAnimation(Theme.spring) { showsTomorrow.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(String(localized: "Morgen · \(agenda.tomorrow.count) Termine", comment: "plural: sidebar, how many calendar meetings tomorrow has"))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(showsTomorrow ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(.small)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 20)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.panel)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("agenda.tomorrow")
        if showsTomorrow {
            ForEach(agenda.tomorrow) { meeting in
                plannedRow(meeting, now: now, isNext: false, showsDay: false)
            }
        }
    }

    private func plannedRow(_ meeting: UpcomingMeeting, now: Date, isNext: Bool, showsDay: Bool = false) -> some View {
        Button {
            navigation.sheet = .upcoming(meeting)
        } label: {
            PlannedMeetingRow(meeting: meeting, now: now, isNext: isNext)
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.panel)
        .listRowSeparator(.hidden)
        .contextMenu { NotMineItems(meeting: meeting) }
        .swipeActions(edge: .trailing) {
            if meeting.end > now {
                Button {
                    Task { await model.startRecording(event: meeting) }
                } label: {
                    Label("Aufnehmen", systemImage: "record.circle")
                }
                .tint(Theme.recordingFill)
            }
        }
    }

    // MARK: Meetings

    private func meetingRow(_ row: MeetingRow) -> some View {
        let selected = wide && navigation.meetingInSplit[.meetings] == row.id
        return Button {
            navigation.open(meeting: row.id)
        } label: {
            MobileMeetingRow(row: row)
        }
        .buttonStyle(RowButtonStyle())
        .listRowInsets(EdgeInsets())
        .listRowBackground(selected ? Theme.selected : Theme.panel)
        .listRowSeparator(.hidden)
        .contextMenu {
            MeetingMenuItems(meetingId: row.id) { deleting = row }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.meeting.status != .recording {
                Button(role: .destructive) {
                    deleting = row
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
    }
}

/// A calendar meeting in the day plan: when, a dashed circle, the title; the next one says how soon, and those that
/// are over without a recording fade.
struct PlannedMeetingRow: View {
    var meeting: UpcomingMeeting
    var now: Date
    var isNext: Bool
    @ScaledMetric(relativeTo: .callout) private var glyphSize: CGFloat = 16

    var body: some View {
        let over = meeting.end <= now
        HStack(alignment: .top, spacing: 12) {
            MeetingGlyph(state: .upcoming, size: glyphSize)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(isNext ? .uiSemibold : .uiMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 7) {
                    Text(over ? TimeFormat.time(meeting.start) : "\(TimeFormat.time(meeting.start))–\(TimeFormat.time(meeting.end))").monospacedDigit()
                    if isNext {
                        Text(TimeFormat.relative(to: meeting.start, now: now)).foregroundStyle(Theme.textSecondary)
                    } else if over {
                        Text("Nicht aufgenommen", comment: "a calendar meeting that is over and was not recorded")
                    }
                    if let app = meeting.app { Text(app) }
                }
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !meeting.attendees.isEmpty {
                AvatarStack(kinds: meeting.attendees.map { .person(name: $0.name) }, size: 22, limit: 3, ring: Theme.panel)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .background {
            if isNext {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            }
        }
        .opacity(over ? 0.5 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meeting.title), \(TimeFormat.time(meeting.start))")
        .accessibilityValue(over ? String(localized: "Nicht aufgenommen", comment: "a calendar meeting that is over and was not recorded") : (isNext ? TimeFormat.relative(to: meeting.start, now: now) : ""))
        .accessibilityHint(Text("Zeigt, wer eingeladen ist, und nimmt auf"))
        .accessibilityIdentifier("planned-\(meeting.eventId)")
    }
}

/// Where the day stands: a quiet grey line with the time, between what has started and what is still to come.
struct MobileNowLine: View {
    var now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.textSecondary).frame(width: 6, height: 6)
            Text(TimeFormat.compactTime(now))
                .font(.tinySemibold)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Rectangle().fill(Theme.textTertiary.opacity(0.45)).frame(height: 1)
        }
        .padding(.leading, 25)
        .padding(.trailing, 16)
        .frame(height: 18)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.panel)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Jetzt, \(TimeFormat.time(now))", comment: "sidebar: the line that marks the current time"))
    }
}

/// A calendar meeting that hasn't been recorded, in a sheet: the same card the Mac shows in a popover.
struct UpcomingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var meeting: UpcomingMeeting
    @State private var height: CGFloat = 300

    var body: some View {
        ScrollView {
            UpcomingPopover(meeting: meeting) { dismiss() }
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.panel)
        // As tall as the card, so the meetings stay in view above it.
        .presentationDetents([.height(height + 20), .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
