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
            if !detail.speakers.isEmpty, detail.speakersSettled {
                heading(String(localized: "Personen"))
                    .padding(.top, showsTimeFacts || hasOtherFacts ? 22 : 0)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(speakers) { speaker in
                        PersonLine(detail: detail, speaker: speaker, doubts: doubts(of: speaker))
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

    /// What the app isn't sure about in a speaker's lines: the groups of them worth naming on their own, those that
    /// sound clearly different and not like the speaker as other meetings know them (short answers often do), and the
    /// other lines it moved here. Lines the user put somewhere are settled.
    private func doubts(of speaker: MeetingSpeaker) -> SpeakerDoubts {
        let all = voiceGroups[speaker.key] ?? []
        var doubts = SpeakerDoubts(main: all.first)
        let groups = SpeakerVoices.notable(all)
        if groups.count > 1 {
            let own = speaker.personId ?? (speaker.isMe ? model.me?.id : nil)
            let threshold = model.settings.voiceStrictness.thresholds.suggestion
            let lines = Dictionary(detail.segments.compactMap { line in line.id.map { ($0, line) } }, uniquingKeysWith: { first, _ in first })
            for (index, group) in groups.enumerated().dropFirst() {
                if let own, let best = model.voiceLibrary.rank(group.centroid, without: detail.meeting.id).first,
                   best.personId == own, best.similarity >= threshold { continue }
                let open = group.segmentIds.compactMap { lines[$0] }.filter { $0.placement != .user }.sorted { $0.start < $1.start }
                guard open.reduce(0, { $0 + $1.duration }) >= SpeakerVoices.minimumSpeech else { continue }
                doubts.voices.append(SpeakerDoubts.Voice(number: index + 1, group: group, lines: open))
            }
        }
        // A moved line that sounds like one of those groups is asked about with it.
        let grouped = Set(doubts.voices.flatMap(\.lines).compactMap(\.id))
        doubts.moved = detail.segments.filter { $0.speakerKey == speaker.key && $0.placement == .app && !grouped.contains($0.id ?? -1) }
        return doubts
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
/// a voice that sounds like two) waits behind the ⓘ, which opens the review.
struct PersonLine: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let doubts: SpeakerDoubts
    @State private var reviewing = false

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
            if !doubts.isEmpty {
                Button {
                    reviewing = true
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
                .debugFrame("review.\(speaker.key)")
            }
        }
        .frame(minHeight: Platform.isMobile ? 48 : 38)
        .sheet(isPresented: $reviewing) {
            VoiceReviewSheet(detail: detail, speaker: speaker, doubts: doubts)
        }
    }

    private var subtitle: String {
        let time = TimeFormat.duration(speaker.talkTime)
        return speaker.isMe ? "\(Strings.me) · \(time)" : time
    }

    private var detailsHelp: String {
        !doubts.voices.isEmpty
            ? String(localized: "Klingt nach \(doubts.voices.count + 1) Stimmen", comment: "plural: one speaker's lines sound like this many voices")
            : String(localized: "\(doubts.moved.count) Zeilen von der App hierher verschoben", comment: "plural: lines the app moved to this speaker")
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
