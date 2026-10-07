import SwiftUI

/// "Wer ist das?": the voices still without a name, one after another. The sample plays by itself, the
/// app's guesses come first, a number key or Return names the voice and the next one follows.
struct NameVoicesPanel: View {
    @Environment(AppModel.self) private var model
    let meetingId: String?

    @State private var queue: [VoiceReview] = []
    @State private var position = 0
    @State private var current: Item?
    @State private var newName = ""
    @State private var addingPerson = false
    @State private var named = 0
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case panel
        case name
    }

    /// What the panel shows about the voice it asks about.
    struct Item {
        var speaker: MeetingSpeaker
        var meeting: Meeting
        var quotes: [String]
        var choices: [Choice]
    }

    struct Choice: Identifiable {
        enum Kind {
            case person(Person)
            case newPerson(name: String, email: String?)
        }

        var kind: Kind
        var detail: String?
        var isGuess: Bool

        var id: String {
            switch kind {
            case .person(let person): person.id
            case .newPerson(let name, _): "new:\(name)"
            }
        }

        var name: String {
            switch kind {
            case .person(let person): person.name
            case .newPerson(let name, _): name
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
            if let current {
                content(current)
            } else {
                done
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 30, y: 16)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .panel)
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.return) {
            guard focus == .panel, let first = current?.choices.first else { return .ignored }
            choose(first)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard focus == .panel else { return .ignored }
            advance()
            return .handled
        }
        .onKeyPress(.space) {
            guard focus == .panel else { return .ignored }
            playSample()
            return .handled
        }
        .onKeyPress(characters: .alphanumerics) { press in
            guard focus == .panel, let current else { return .ignored }
            let key = press.characters.lowercased()
            if let number = Int(key), number >= 1, number <= min(9, current.choices.count) {
                choose(current.choices[number - 1])
                return .handled
            }
            // The letters of the interface's language, and the German ones, which always work.
            if key == Shortcut.newPerson.lowercased() || key == "n" {
                addingPerson = true
                focus = .name
            } else if key == Shortcut.me.lowercased() || key == "d" {
                model.assignToMe(current.speaker)
                next(named: true)
            } else if key == Shortcut.nobody.lowercased() || key == "x" {
                model.ignoreVoice(current.speaker)
                next(named: false)
            } else {
                return .ignored
            }
            return .handled
        }
        .onAppear {
            queue = model.voicesToName(first: meetingId)
            position = 0
            load()
            focus = .panel
        }
        .onDisappear { model.player.stop() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            Text("Wer ist das?").font(.system(size: 15, weight: .semibold))
            Spacer()
            if current != nil, queue.count > 1 {
                Text("\(min(position + 1, queue.count)) von \(queue.count)")
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            IconButton(systemName: "xmark", label: String(localized: "Schließen (esc)"), size: 22) { close() }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    private func content(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: playSample) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.onColor)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.accentFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Stimmprobe anhören (Leertaste)")
                .disabled(item.speaker.sampleStart == nil || !AudioArchiver.hasAudio(meetingId: item.meeting.id))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.speaker.displayLabel) · \(TimeFormat.duration(item.speaker.talkTime)) Sprache")
                        .font(.uiSemibold)
                    Text("\(item.meeting.title) · \(TimeFormat.compactDay(item.meeting.startedAt))")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                    ForEach(item.quotes, id: \.self) { quote in
                        Text(Strings.quote(quote))
                            .font(.small)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(18)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.choices.prefix(9).enumerated()), id: \.element.id) { index, choice in
                    if index == 0 && choice.isGuess {
                        sectionTitle(item.choices.filter(\.isGuess).count > 1 ? String(localized: "Vermutlich einer von ihnen") : String(localized: "Vermutlich", comment: "section title over the person a voice probably is"))
                    } else if !choice.isGuess && (index == 0 || item.choices[index - 1].isGuess) {
                        sectionTitle(String(localized: "Andere", comment: "section title over the other people a voice could be"))
                    }
                    ChoiceRow(number: index + 1, choice: choice, highlighted: index == 0) { choose(choice) }
                }
                if item.choices.count > 9 {
                    Menu("Weitere …") {
                        ForEach(item.choices.dropFirst(9)) { choice in
                            Button(choice.name) { choose(choice) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .font(.small)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .fixedSize()
                }
                newPersonRow
            }
            .padding(.horizontal, 12)

            Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.top, 12)
            HStack(spacing: 14) {
                footerButton("Das bin ich", key: Shortcut.me) {
                    model.assignToMe(item.speaker)
                    next(named: true)
                }
                footerButton("Niemand Bestimmtes", key: Shortcut.nobody) {
                    model.ignoreVoice(item.speaker)
                    next(named: false)
                }
                Spacer()
                footerButton("Überspringen", key: "→") { advance() }
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
        }
    }

    private var newPersonRow: some View {
        HStack(spacing: 10) {
            Keycap(Shortcut.newPerson)
            if addingPerson {
                TextField("Name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.ui)
                    .focused($focus, equals: .name)
                    .onSubmit(saveNewPerson)
                    .onExitCommand {
                        addingPerson = false
                        newName = ""
                        focus = .panel
                    }
                Button("Sichern") { saveNewPerson() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                Button {
                    addingPerson = true
                    focus = .name
                } label: {
                    Text("Neue Person …").foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PlainPressStyle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(Theme.positive)
            Text(named > 0 ? "Alle Stimmen haben einen Namen." : "Keine Stimme wartet auf einen Namen.")
                .font(.uiMedium)
            Text("Die App erkennt die Stimmen jetzt auch in anderen Meetings und sortiert dort nach.")
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Fertig") { close() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.smallMedium)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// One-letter keys for the choices that aren't numbered, taken from their words in the interface's language.
    private enum Shortcut {
        static var me: String { String(localized: "D", comment: "one-letter key for \"Das bin ich\" (That's me), ideally its first letter; not a digit, and not the same as the keys for \"Niemand Bestimmtes\" and a new name") }
        static var nobody: String { String(localized: "X", comment: "one-letter key for \"Niemand Bestimmtes\" (nobody in particular); not a digit, and not the same as the keys for \"Das bin ich\" and a new name") }
        static var newPerson: String { String(localized: "N", comment: "one-letter key for typing a new name in the Who is this panel, ideally the first letter of \"Name\"; not a digit, and not the same as the keys for \"Das bin ich\" and \"Niemand Bestimmtes\"") }
    }

    private func footerButton(_ title: LocalizedStringKey, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Keycap(key)
            }
            .font(.small)
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(PlainPressStyle())
    }

    // MARK: Actions

    private var isPlaying: Bool {
        guard let current else { return false }
        return model.player.isPlaying && model.player.meetingId == current.meeting.id && model.player.stopAt != nil
    }

    private func playSample() {
        guard let current, let start = current.speaker.sampleStart, let end = current.speaker.sampleEnd else { return }
        if isPlaying {
            model.player.toggle()
        } else {
            Task { await model.player.play(meetingId: current.meeting.id, from: start, until: end) }
        }
    }

    private func choose(_ choice: Choice) {
        guard let current else { return }
        switch choice.kind {
        case .person(let person):
            if person.isMe { model.assignToMe(current.speaker) } else { model.assign(current.speaker, to: person.id) }
        case .newPerson(let name, let email):
            model.assign(current.speaker, toNewPersonNamed: name, email: email)
        }
        next(named: true)
    }

    private func saveNewPerson() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, !name.isEmpty else { return }
        model.assign(current.speaker, toNewPersonNamed: name)
        newName = ""
        addingPerson = false
        focus = .panel
        next(named: true)
    }

    private func next(named didName: Bool) {
        if didName { named += 1 }
        advance()
    }

    private func advance() {
        position += 1
        load()
    }

    private func close() {
        model.player.stop()
        model.overlay = nil
    }

    /// The next voice that still waits: naming one voice can let the app recognise others by itself.
    private func load() {
        model.player.stop()
        current = nil
        while position < queue.count {
            let review = queue[position]
            if let detail = try? model.database.detail(of: review.speaker.meetingId),
               let speaker = detail.speaker(for: review.speaker.key), speaker.needsReview {
                current = item(for: speaker, in: detail)
                playSample()
                return
            }
            position += 1
        }
    }

    private func item(for speaker: MeetingSpeaker, in detail: MeetingDetail) -> Item {
        let quotes = detail.segments.filter { $0.speakerKey == speaker.key && $0.duration >= 2 }
            .sorted { $0.duration > $1.duration }
            .prefix(2)
            .map { String($0.text.prefix(140)) }
        return Item(speaker: speaker, meeting: detail.meeting, quotes: quotes, choices: choices(for: speaker, in: detail))
    }

    /// The app's guesses first (with why), then a name said in the meeting, the invitees, everyone else.
    private func choices(for speaker: MeetingSpeaker, in detail: MeetingDetail) -> [Choice] {
        var result: [Choice] = []
        var listed = Set<String>()
        let similarity: [String: Float] = speaker.embedding.map { data in
            Dictionary(model.voiceLibrary.rank([Float](embeddingData: data), excludingMeeting: detail.meeting.id).map { ($0.personId, $0.similarity) }, uniquingKeysWith: max)
        } ?? [:]
        func voiceDetail(_ personId: String) -> String? {
            guard let value = similarity[personId] else { return nil }
            return value >= 0.72 ? String(localized: "klingt sehr ähnlich", comment: "how much an unknown voice sounds like this person") : (value >= 0.55 ? String(localized: "klingt ähnlich", comment: "how much an unknown voice sounds like this person") : String(localized: "klingt etwas ähnlich", comment: "how much an unknown voice sounds like this person"))
        }
        for personId in speaker.guesses {
            guard let person = model.person(personId) ?? detail.people[personId], !listed.contains(person.id) else { continue }
            listed.insert(person.id)
            let reason = personId == speaker.suggestedPersonId && !SpeakerIdentifier.isVoiceReason(speaker.suggestionReason) ? speaker.displayReason : voiceDetail(personId)
            result.append(Choice(kind: .person(person), detail: reason, isGuess: true))
        }
        if speaker.suggestedPersonId == nil, let name = speaker.suggestedName {
            let attendee = detail.meeting.attendees.first { $0.name == name }
            result.append(Choice(kind: .newPerson(name: name, email: attendee?.email), detail: speaker.displayReason.map { String(localized: "neu · \($0)", comment: "a person not known yet, then why the app suggests them") } ?? String(localized: "neu", comment: "a person not known yet"), isGuess: true))
            listed.insert("new:\(name)")
        }
        for attendee in detail.meeting.attendees {
            if let person = model.people.first(where: { !$0.isMe && (($0.email != nil && $0.email?.lowercased() == attendee.email?.lowercased()) || $0.name == attendee.name) }) {
                guard !listed.contains(person.id) else { continue }
                listed.insert(person.id)
                result.append(Choice(kind: .person(person), detail: String(localized: "eingeladen", comment: "the person was invited to the meeting"), isGuess: false))
            } else if !listed.contains("new:\(attendee.name)") {
                listed.insert("new:\(attendee.name)")
                result.append(Choice(kind: .newPerson(name: attendee.name, email: attendee.email), detail: String(localized: "eingeladen · neu", comment: "the person was invited to the meeting and is not known yet"), isGuess: false))
            }
        }
        for person in model.people where !person.isMe && !listed.contains(person.id) {
            listed.insert(person.id)
            result.append(Choice(kind: .person(person), detail: voiceDetail(person.id), isGuess: false))
        }
        return result
    }
}

private struct ChoiceRow: View {
    let number: Int
    let choice: NameVoicesPanel.Choice
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Keycap(highlighted ? "↩" : "\(number)")
                    .frame(width: 26)
                Avatar(kind: .person(name: choice.name), size: 20)
                Text(choice.name).font(.uiMedium).lineLimit(1)
                if let detail = choice.detail {
                    Text(detail).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || highlighted ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .help(highlighted ? "Return oder \(number)" : "Taste \(number)")
    }
}
