import AppKit
import SwiftUI

/// The column on the right of a meeting: facts, the voices and who they are.
struct Inspector: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    private var remoteSpeakers: [MeetingSpeaker] {
        detail.speakers.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return !lhs.isMe }
            return lhs.talkTime > rhs.talkTime
        }
    }

    private var totalTalk: Double {
        max(detail.speakers.reduce(0) { $0 + $1.talkTime }, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                facts
                if !detail.speakers.isEmpty {
                    divider
                    Text("Sprecher").font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.bottom, 12)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(remoteSpeakers) { speaker in
                            SpeakerRow(detail: detail, speaker: speaker, share: speaker.talkTime / totalTalk)
                        }
                    }
                    ForEach(detail.speakers.filter { $0.assignment == .suggested }) { speaker in
                        SuggestionCard(detail: detail, speaker: speaker)
                            .padding(.top, 14)
                    }
                }
                if !detail.markers.isEmpty {
                    divider
                    Text("Markierungen").font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.bottom, 10)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detail.markers) { marker in
                            Button {
                                Task { await model.player.play(meetingId: detail.meeting.id, from: max(0, marker.time - 5)) }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                                    Text(TimeFormat.clock(marker.time)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                                    Text(marker.text.isEmpty ? "Markierung" : marker.text).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainPressStyle())
                            .help("Hier abspielen")
                        }
                    }
                }
                if let model = detail.meeting.transcriptionModel {
                    Text("Lokal transkribiert · \(model)")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 28)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.vertical, 18)
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 11) {
            fact("Datum", TimeFormat.shortDate(detail.meeting.startedAt))
            fact("Dauer", TimeFormat.duration(detail.meeting.duration))
            if let source = detail.meeting.source { fact("Quelle", source) }
            if let language = detail.meeting.language, let name = Locale(identifier: "de_DE").localizedString(forLanguageCode: language) {
                fact("Sprache", name)
            }
            if !detail.meeting.attendees.isEmpty {
                GridRow {
                    Text("Eingeladen").foregroundStyle(Theme.textTertiary)
                    Text(detail.meeting.attendees.map(\.name).joined(separator: ", "))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(value).lineLimit(1)
        }
    }
}

struct SpeakerRow: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let share: Double

    var body: some View {
        Menu {
            SpeakerMenuItems(detail: detail, speaker: speaker)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Avatar(kind: detail.avatarKind(for: speaker.key), size: 18)
                    Text(detail.displayName(for: speaker.key)).lineLimit(1)
                    if speaker.assignment == .automatic {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .help("An der Stimme erkannt")
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((share * 100).rounded())) %").font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
                ThinBar(fraction: share, color: barColor)
                    .padding(.leading, 26)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(speaker.isMe ? "Du (Mikrofon)" : "Klicken, um die Stimme zuzuordnen")
    }

    private var barColor: Color {
        switch detail.avatarKind(for: speaker.key) {
        case .person(let name): Theme.color(for: name)
        case .me: Theme.meColor
        case .unknown: Theme.textTertiary
        }
    }
}

/// Everything you can say about a voice: who it is, or that it's you, or play it back.
struct SpeakerMenuItems: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker

    var body: some View {
        if let start = speaker.sampleStart, let end = speaker.sampleEnd, AudioArchiver.hasAudio(meetingId: detail.meeting.id) {
            Button("Stimmprobe anhören", systemImage: "play") {
                Task { await model.player.play(meetingId: detail.meeting.id, from: start, until: end) }
            }
            Divider()
        }
        if !speaker.isMe {
            let invited = invitees
            if !invited.isEmpty {
                Section("Eingeladen") {
                    ForEach(invited, id: \.name) { attendee in
                        Button(attendee.name) { assign(attendee) }
                    }
                }
            }
            let known = model.people.filter { !$0.isMe && !invited.map(\.name).contains($0.name) }
            if !known.isEmpty {
                Section("Bekannt") {
                    ForEach(known) { person in
                        Button(person.name) { model.assign(speaker, to: person.id) }
                    }
                }
            }
            Button("Neue Person …", systemImage: "person.badge.plus") { NewPersonPrompt.ask(for: speaker, model: model) }
            Button("Das bin ich", systemImage: "person.crop.circle") { model.assignToMe(speaker) }
            if speaker.personId != nil {
                Divider()
                Button("Zuordnung entfernen", systemImage: "xmark") { model.unassign(speaker) }
            }
        }
    }

    private var invitees: [Attendee] {
        detail.meeting.attendees
    }

    private func assign(_ attendee: Attendee) {
        if let person = model.people.first(where: { !$0.isMe && (($0.email != nil && $0.email == attendee.email) || $0.name == attendee.name) }) {
            model.assign(speaker, to: person.id)
        } else {
            model.assign(speaker, toNewPersonNamed: attendee.name, email: attendee.email)
        }
    }
}

/// Asks for a name with a small panel and assigns the voice to a new person.
enum NewPersonPrompt {
    @MainActor
    static func ask(for speaker: MeetingSpeaker, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = "Wer ist \(speaker.label)?"
        alert.informativeText = "Die Stimme wird gemerkt und in künftigen Meetings wiedererkannt."
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = speaker.suggestedName ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.assign(speaker, toNewPersonNamed: field.stringValue)
    }
}

/// "Sprecher 4 is probably Jonas Weber" with the reason and the buttons to settle it.
struct SuggestionCard: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker

    private var name: String {
        speaker.suggestedPersonId.flatMap { detail.people[$0]?.name ?? model.person($0)?.name } ?? speaker.suggestedName ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("\(speaker.label) ist vermutlich").font(.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "Vorschlag verwerfen", size: 20) { model.rejectSuggestion(speaker) }
                    .padding(.top, -3)
                    .padding(.trailing, -4)
            }
            HStack(spacing: 8) {
                Avatar(kind: .person(name: name), size: 18)
                Text(name).font(.uiSemibold).lineLimit(1)
                if speaker.suggestedPersonId == nil {
                    Text("neu").font(.tiny).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.top, 6)
            if let reason = speaker.suggestionReason {
                Text(reason)
                    .font(.small)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                Button("Bestätigen") { model.confirmSuggestion(speaker) }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                Menu {
                    SpeakerMenuItems(detail: detail, speaker: speaker)
                } label: {
                    Text("Andere Person")
                        .font(.small)
                        .foregroundStyle(Theme.textBody)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.chipBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.selectionFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.selectionBorder, lineWidth: 1))
    }
}
