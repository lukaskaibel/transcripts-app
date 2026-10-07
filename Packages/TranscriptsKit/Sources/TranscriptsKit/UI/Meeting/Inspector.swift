import AppKit
import SwiftUI

/// The column on the right of a meeting: facts, the voices and who they are.
struct Inspector: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    /// Each speaker's lines grouped by voice, worked out in the background whenever the lines change.
    @State private var voiceGroups: [String: [SpeakerVoices.Group]] = [:]

    /// Changes whenever a line moves to another speaker or in or out of its voice.
    private var linesSignature: [String] {
        detail.segments.map { "\($0.id ?? 0)\($0.speakerKey)\($0.voiceIgnored ? "-" : "")\($0.embedding == nil ? "" : "v")" }
    }

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
                    Text(String(localized: "Sprecher", comment: "heading over the list of the meeting's speakers (plural)")).font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.bottom, 12)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(remoteSpeakers) { speaker in
                            SpeakerRow(detail: detail, speaker: speaker, share: speaker.talkTime / totalTalk)
                            let groups = otherVoices(of: speaker)
                            if groups.count > 1 {
                                SpeakerGroupsView(detail: detail, speaker: speaker, groups: groups)
                            }
                            let moved = detail.segments.filter { $0.speakerKey == speaker.key && $0.placement == .app }
                            if !moved.isEmpty {
                                MovedLinesNote(detail: detail, speaker: speaker, lines: moved)
                            }
                        }
                    }
                    ForEach(detail.speakers.filter { $0.needsReview && (!detail.guesses(for: $0).isEmpty || $0.suggestedName != nil) }) { speaker in
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
                                    Text(marker.text.isEmpty ? String(localized: "Markierung") : marker.text).lineLimit(2)
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
        .task(id: linesSignature) {
            let segments = detail.segments
            let groups = await Task.detached(priority: .userInitiated) { SpeakerVoices.groups(of: segments) }.value
            guard !Task.isCancelled else { return }
            voiceGroups = groups
        }
    }

    /// The groups of a speaker's lines worth naming on their own: the main one, and those that sound
    /// clearly different and not like the speaker as other meetings know them (short answers often do).
    private func otherVoices(of speaker: MeetingSpeaker) -> [SpeakerVoices.Group] {
        let groups = SpeakerVoices.notable(voiceGroups[speaker.key] ?? [])
        guard groups.count > 1 else { return [] }
        let own = speaker.personId ?? (speaker.isMe ? model.me?.id : nil)
        let threshold = model.settings.voiceStrictness.thresholds.suggestion
        let others = groups.dropFirst().filter { group in
            guard let own, let best = model.voiceLibrary.rank(group.centroid, without: detail.meeting.id).first else { return true }
            return !(best.personId == own && best.similarity >= threshold)
        }
        return others.isEmpty ? [] : [groups[0]] + others
    }

    private var divider: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.vertical, 18)
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 11) {
            fact("Datum", TimeFormat.shortDate(detail.meeting.startedAt))
            fact("Dauer", TimeFormat.duration(detail.meeting.duration))
            if let source = detail.meeting.source { fact("Quelle", source) }
            if let language = detail.meeting.language, let name = AppLocale.current.localizedString(forLanguageCode: language) {
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

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
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
                    Text(share.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current))).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
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
        alert.messageText = String(localized: "Wer ist \(speaker.displayLabel)?")
        alert.informativeText = String(localized: "Die Stimme wird gemerkt und in künftigen Meetings wiedererkannt.")
        alert.addButton(withTitle: String(localized: "Speichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Name")
        field.stringValue = speaker.suggestedName ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.assign(speaker, toNewPersonNamed: field.stringValue)
    }
}

/// "Wer ist Sprecher 4?" with the people the app guesses (one or a few), why, and one click each.
struct SuggestionCard: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker

    private var guesses: [Person] {
        detail.guesses(for: speaker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(guesses.count > 1 ? "Wer ist \(speaker.displayLabel)?" : "\(speaker.displayLabel) ist vermutlich").font(.small).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: guesses.count > 1 ? String(localized: "Keiner davon") : String(localized: "Vorschlag verwerfen"), size: 20) { model.rejectGuesses(speaker) }
                    .padding(.top, -3)
                    .padding(.trailing, -4)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(guesses) { person in
                    guessRow(name: person.name, reason: reason(for: person.id)) { model.assign(speaker, to: person.id) }
                }
                if speaker.suggestedPersonId == nil, let name = speaker.suggestedName {
                    guessRow(name: name, reason: speaker.displayReason, isNew: true) { model.confirmSuggestion(speaker) }
                }
            }
            .padding(.top, 6)
            HStack(spacing: 6) {
                if guesses.count + (speaker.suggestedPersonId == nil && speaker.suggestedName != nil ? 1 : 0) == 1 {
                    Button("Bestätigen") { model.confirmSuggestion(speaker) }
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                }
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

    private func reason(for personId: String) -> String? {
        if personId == speaker.suggestedPersonId { return speaker.displayReason }
        return String(localized: "Stimme ähnlich")
    }

    private func guessRow(name: String, reason: String?, isNew: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Avatar(kind: .person(name: name), size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.uiSemibold).lineLimit(1)
                        if isNew { Text(String(localized: "neu", comment: "badge next to a suggested name: this person isn't known yet")).font(.tiny).foregroundStyle(Theme.textTertiary) }
                    }
                    if let reason {
                        Text(reason)
                            .font(.small)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .help("\(name) zuordnen")
    }
}

/// Lines the app moved to this speaker because they sound like them, with the way to keep or undo that.
struct MovedLinesNote: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let lines: [Segment]

    var body: some View {
        let ids = lines.compactMap(\.id)
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "\(lines.count) Zeilen von der App hierher verschoben", comment: "plural: lines the app moved to this speaker"))
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
            Text(origins)
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Button(String(localized: "Passt", comment: "keep the lines the app moved to this speaker")) { model.acceptMovedLines(ids) }
                Button(String(localized: "Zurück", comment: "move the lines back to the speaker they came from")) { model.returnMovedLines(ids, in: detail.meeting.id) }
                if let first = lines.first {
                    Button("Anhören") {
                        Task { await model.player.play(meetingId: detail.meeting.id, from: first.start, until: min(first.end, first.start + 12)) }
                    }
                    .disabled(!AudioArchiver.hasAudio(meetingId: detail.meeting.id))
                }
            }
            .buttonStyle(PlainPressStyle())
            .font(.small.weight(.medium))
            .foregroundStyle(Theme.accent)
        }
        .padding(.leading, 26)
        .padding(.top, -4)
    }

    private var origins: String {
        let from = Set(lines.compactMap(\.movedFromKey)).map { detail.displayName(for: $0) }.sorted()
        let quote = lines.max { $0.duration < $1.duration }.map { Strings.quote(String($0.text.prefix(60))) } ?? ""
        return from.isEmpty ? quote : String(localized: "Vorher bei \(from.joined(separator: ", ")) · \(quote)", comment: "the speakers the lines were with before, then a quote of the longest line")
    }
}

/// A speaker whose lines sound like more than one voice: each group to listen to and name on its own.
struct SpeakerGroupsView: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let groups: [SpeakerVoices.Group]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(speaker.isMe
                ? String(localized: "Auf deinem Mikrofon klingen \(groups.count) Stimmen", comment: "plural: different voices on the user's microphone")
                : String(localized: "Klingt nach \(groups.count) Stimmen", comment: "plural: one speaker's lines sound like this many voices"))
                .font(.small)
                .foregroundStyle(Theme.warning)
                .padding(.bottom, 2)
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                SpeakerGroupRow(detail: detail, speaker: speaker, group: group, number: index + 1)
            }
        }
        .padding(.leading, 26)
        .padding(.top, -4)
    }
}

private struct SpeakerGroupRow: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let group: SpeakerVoices.Group
    let number: Int

    /// Whom the group sounds like, leaving out what this meeting taught the app.
    private var match: (name: String, isMe: Bool, similarity: Float)? {
        let excluded: Set<String> = speaker.isMe ? [] : Set([model.me?.id].compactMap { $0 })
        guard let best = model.voiceLibrary.rank(group.centroid, excluding: excluded, without: detail.meeting.id).first,
              best.similarity >= model.settings.voiceStrictness.thresholds.suggestion,
              let person = model.person(best.personId) else { return nil }
        return (person.firstName, person.isMe, best.similarity)
    }

    var body: some View {
        HStack(spacing: 8) {
            PlayDot(meetingId: detail.meeting.id, start: group.example.start, end: min(group.example.end, group.example.start + 12))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Stimme \(number)").font(.smallMedium)
                    Text(TimeFormat.duration(group.speech)).font(.small).foregroundStyle(Theme.textTertiary)
                }
                Text(match.map { $0.isMe ? String(localized: "klingt wie dir", comment: "these lines sound like the user") : String(localized: "klingt wie \($0.name)", comment: "these lines sound like this person") } ?? Strings.quote(group.example.text))
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .help(group.example.text)
            }
            Spacer(minLength: 4)
            Menu {
                Section("Gehört zu") {
                    PersonChoices(attendees: detail.meeting.attendees) { personId in
                        model.assignLines(group.segmentIds, in: detail.meeting.id, to: personId)
                    } newPerson: {
                        if let name = NamePrompt.ask(title: String(localized: "Wer ist das?"), message: String(localized: "Diese Zeilen werden der Person zugeordnet und ihre Stimme gemerkt.")) {
                            model.assignLines(group.segmentIds, in: detail.meeting.id, toNewPersonNamed: name)
                        }
                    }
                }
                Divider()
                Button("Als eigene Stimme abtrennen", systemImage: "scissors") { model.separateLines(group.segmentIds, in: detail.meeting.id) }
                Button("Nicht für die Stimme verwenden", systemImage: "nosign") { model.setLinesIgnored(group.segmentIds, ignored: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diese Zeilen jemandem zuordnen")
        }
        .frame(minHeight: 32)
    }
}
