import SwiftUI

/// The column on the right of a meeting, as Notebook's outline: the facts, the people who spoke, the bookmarks. On
/// the Mac and a wide iPad it stands beside the meeting; on the iPhone its content sits under the summary.
struct Inspector: View {
    let detail: MeetingDetail

    var body: some View {
        ScrollView {
            InspectorContent(detail: detail)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the inspector shows. `showsTimeFacts` is off where the date, the length and the source already stand under
/// the meeting's title.
struct InspectorContent: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    var showsTimeFacts = true
    /// Each speaker's lines grouped by voice, worked out in the background whenever the lines change.
    @State private var voiceGroups: [String: [SpeakerVoices.Group]] = [:]

    /// Changes whenever a line moves to another speaker or in or out of its voice.
    private var linesSignature: [String] {
        detail.segments.map { "\($0.id ?? 0)\($0.speakerKey)\($0.voiceIgnored ? "-" : "")\($0.embedding == nil ? "" : "v")" }
    }

    /// The people with a name first, longest talkers first; the voices without a name after them; you last.
    private var speakers: [MeetingSpeaker] {
        detail.speakers.sorted { lhs, rhs in
            if lhs.isMe != rhs.isMe { return !lhs.isMe }
            if lhs.needsReview != rhs.needsReview { return !lhs.needsReview }
            return lhs.talkTime > rhs.talkTime
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTimeFacts || hasOtherFacts {
                heading(String(localized: "Details", comment: "inspector: heading over a meeting's date, length, source and language"))
                facts
            }
            if !detail.speakers.isEmpty {
                heading(String(localized: "Personen"))
                    .padding(.top, showsTimeFacts || hasOtherFacts ? 22 : 0)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(speakers) { speaker in
                        let groups = otherVoices(of: speaker)
                        let moved = detail.segments.filter { $0.speakerKey == speaker.key && $0.placement == .app }
                        PersonLine(detail: detail, speaker: speaker, groups: groups, moved: moved)
                    }
                }
            }
            if !detail.markers.isEmpty {
                heading(String(localized: "Markierungen")).padding(.top, 22)
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
                    .font(.tiny)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 26)
            }
        }
        .task(id: linesSignature) {
            let segments = detail.segments
            let groups = await Task.detached(priority: .userInitiated) { SpeakerVoices.groups(of: segments) }.value
            guard !Task.isCancelled else { return }
            voiceGroups = groups
        }
    }

    /// A heading as the sidebar's: small, grey, semibold.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.tinySemibold)
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
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

    /// Facts that don't stand under the title: the language and the invitees.
    private var hasOtherFacts: Bool {
        detail.meeting.language != nil || !detail.meeting.attendees.isEmpty
    }

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
            if showsTimeFacts {
                fact("Datum", TimeFormat.shortDate(detail.meeting.startedAt))
                fact("Dauer", TimeFormat.duration(detail.meeting.duration))
                if let source = detail.meeting.source { fact("Quelle", source) }
            }
            if let language = detail.meeting.language, let name = AppLocale.current.localizedString(forLanguageCode: language) {
                fact("Sprache", name)
            }
            if !detail.meeting.attendees.isEmpty {
                GridRow {
                    Text("Eingeladen").foregroundStyle(Theme.textTertiary)
                    Text(detail.meeting.attendees.map(\.name).joined(separator: ", "))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.small)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textTertiary)
            Text(value).lineLimit(1)
        }
    }
}

/// One person in the meeting, as a contact: the picture, the name and how long they spoke. A voice without a name
/// shows its label in grey. A click opens the menu that names it; what the app isn't sure about (lines it moved,
/// a voice that sounds like two) waits behind the ⓘ.
struct PersonLine: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let groups: [SpeakerVoices.Group]
    let moved: [Segment]
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                SpeakerMenuItems(detail: detail, speaker: speaker)
            } label: {
                HStack(spacing: 10) {
                    Avatar(kind: detail.avatarKind(for: speaker.key), size: Platform.isMobile ? 32 : 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(detail.settledName(for: speaker.key))
                            .font(.ui)
                            .foregroundStyle(speaker.needsReview ? Theme.textSecondary : Theme.text)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.tiny)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(speaker.isMe ? "Du (Mikrofon)" : "Klicken, um die Stimme zuzuordnen")
            if !groups.isEmpty || !moved.isEmpty {
                Button {
                    showsDetails = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: Platform.isMobile ? 17 : 13))
                        .foregroundStyle(Theme.warning)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help(detailsHelp)
                .accessibilityLabel(detailsHelp)
                .popover(isPresented: $showsDetails, arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: 14) {
                        if groups.count > 1 {
                            SpeakerGroupsView(detail: detail, speaker: speaker, groups: groups)
                        }
                        if !moved.isEmpty {
                            MovedLinesNote(detail: detail, speaker: speaker, lines: moved)
                        }
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
            }
        }
        .frame(minHeight: Platform.isMobile ? 48 : 38)
    }

    private var subtitle: String {
        let time = TimeFormat.duration(speaker.talkTime)
        return speaker.isMe ? "\(Strings.me) · \(time)" : time
    }

    private var detailsHelp: String {
        groups.count > 1
            ? String(localized: "Klingt nach \(groups.count) Stimmen", comment: "plural: one speaker's lines sound like this many voices")
            : String(localized: "\(moved.count) Zeilen von der App hierher verschoben", comment: "plural: lines the app moved to this speaker")
    }
}

/// Everything you can say about a voice: who it is (the app's guesses first), that it's you, or play it back.
struct SpeakerMenuItems: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker

    var body: some View {
        if !speaker.isMe {
            let guesses = guessed
            Section(speaker.personId == nil ? String(localized: "Stimme benennen", comment: "menu section: name a voice") : String(localized: "Andere Person", comment: "menu section: give a named voice to someone else")) {
                ForEach(guesses) { person in
                    Button {
                        model.assign(speaker, to: person.id)
                    } label: {
                        Text(person.name)
                        Text(person.id == speaker.suggestedPersonId ? (speaker.displayReason ?? String(localized: "Vorschlag")) : String(localized: "Stimme ähnlich"))
                    }
                }
                if speaker.suggestedPersonId == nil, let name = speaker.suggestedName, speaker.personId == nil {
                    Button {
                        model.confirmSuggestion(speaker)
                    } label: {
                        Text(name)
                        Text(speaker.displayReason ?? String(localized: "Vorschlag"))
                    }
                }
                let invited = invitees.filter { attendee in !guesses.contains { $0.name == attendee.name } }
                ForEach(invited, id: \.name) { attendee in
                    Button(attendee.name) { assign(attendee) }
                }
                let known = model.people.filter { person in
                    !person.isMe && !invitees.map(\.name).contains(person.name) && !guesses.contains { $0.id == person.id } && person.id != speaker.personId
                }
                if !known.isEmpty {
                    Menu("Bekannt") {
                        ForEach(known) { person in
                            Button(person.name) { model.assign(speaker, to: person.id) }
                        }
                    }
                }
                Button("Neue Person …", systemImage: "person.badge.plus") { NamePrompt.newPerson(for: speaker, model: model) }
                Button("Das bin ich", systemImage: "person.crop.circle") { model.assignToMe(speaker) }
            }
            if speaker.personId != nil {
                Button("Zuordnung entfernen", systemImage: "xmark") { model.unassign(speaker) }
            } else if speaker.needsReview {
                Button("Niemand Bestimmtes", systemImage: "person.slash") { model.ignoreVoice(speaker) }
            }
        }
        if let start = speaker.sampleStart, let end = speaker.sampleEnd, AudioArchiver.hasAudio(meetingId: detail.meeting.id) {
            Divider()
            Button("Stimmprobe anhören", systemImage: "play") {
                Task { await model.player.play(meetingId: detail.meeting.id, from: start, until: end) }
            }
        }
    }

    /// The people the app thinks the voice is, while it isn't settled.
    private var guessed: [Person] {
        speaker.personId == nil ? detail.guesses(for: speaker) : []
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
                        NamePrompt.ask(title: String(localized: "Wer ist das?"), message: String(localized: "Diese Zeilen werden der Person zugeordnet und ihre Stimme gemerkt.")) { name in
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
