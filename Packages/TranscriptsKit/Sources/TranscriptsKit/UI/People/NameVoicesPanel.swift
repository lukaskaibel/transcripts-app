import SwiftUI

/// Naming the voices still without a name, one after another, as Photos asks about a face: the voice plays, the app
/// says whom it thinks it is ("Ist das Jonas Weber?"), and Yes or Someone Else settles it; then the next one. The Mac
/// shows it as a sheet on the window, iPhone and iPad as a sheet from the bottom. Return says yes, Space plays the
/// voice again, → skips it and Escape stops for now.
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

        /// The app's best guess, if it has one.
        var guess: Choice? { choices.first.flatMap { $0.isGuess ? $0 : nil } }
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

        var firstName: String {
            name.split(separator: " ").first.map(String.init) ?? name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let current {
                content(current)
            } else {
                done
            }
        }
        .padding(.horizontal, Platform.isMobile ? 20 : 22)
        .padding(.top, Platform.isMobile ? 14 : 20)
        .padding(.bottom, Platform.isMobile ? 12 : 18)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .panel)
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
        .onAppear {
            queue = model.voicesToName(first: meetingId)
            position = 0
            load()
            focus = .panel
        }
        .onDisappear { model.player.stop() }
    }

    // MARK: Parts

    private func content(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            clip(item).padding(.top, 14)
            question(item).padding(.top, 20)
            if addingPerson {
                newPersonField.padding(.top, 20)
            } else {
                answers(item).padding(.top, 20)
            }
            footer.padding(.top, Platform.isMobile ? 6 : 14)
        }
    }

    private func header(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.speaker.displayLabel).font(Platform.isMobile ? .headline : .uiSemibold)
                Text("\(item.meeting.title) · \(TimeFormat.compactDay(item.meeting.startedAt)) · \(TimeFormat.duration(item.speaker.talkTime)) Sprache")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if queue.count > 1 {
                Text("\(min(position + 1, queue.count)) von \(queue.count)")
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// The voice to listen to, with what it said.
    private func clip(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: playSample) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: Platform.isMobile ? 16 : 13))
                        .foregroundStyle(.white)
                        .frame(width: Platform.isMobile ? 44 : 36, height: Platform.isMobile ? 44 : 36)
                        .background(Circle().fill(Theme.accentFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Stimmprobe anhören (Leertaste)")
                .accessibilityLabel("Stimmprobe anhören")
                .disabled(item.speaker.sampleStart == nil || !AudioArchiver.hasAudio(meetingId: item.meeting.id))
                ThinBar(fraction: sampleProgress(item), height: 4)
                if let start = item.speaker.sampleStart, let end = item.speaker.sampleEnd {
                    Text(TimeFormat.clock(end - start)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
            }
            ForEach(item.quotes, id: \.self) { quote in
                Text(Strings.quote(quote))
                    .font(Platform.isMobile ? .subheadline : .ui)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.suggestion))
    }

    /// "Ist das Jonas Weber?" with why the app thinks so, or "Wer ist das?" when it has no idea.
    private func question(_ item: Item) -> some View {
        VStack(spacing: 6) {
            if let guess = item.guess {
                Avatar(kind: .person(name: guess.name), size: Platform.isMobile ? 60 : 52)
                Text("Ist das \(guess.name)?", comment: "naming a voice: whom the app thinks it is")
                    .font(Platform.isMobile ? .title2.bold() : .system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 6)
                if let reason = guess.detail {
                    Text(reason)
                }
            } else {
                Avatar(kind: .unknown(label: item.speaker.label), size: Platform.isMobile ? 60 : 52)
                Text("Wer ist das?")
                    .font(Platform.isMobile ? .title2.bold() : .system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 6)
                Text("Im Gespräch fiel kein Name, und die Stimme klingt nach niemandem, den du schon benannt hast.", comment: "naming a voice the app has no guess for")
            }
        }
        .font(Platform.isMobile ? .subheadline : .ui)
        .foregroundStyle(Theme.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    /// Yes and Someone Else side by side on the Mac, stacked for a thumb on iPhone and iPad.
    @ViewBuilder
    private func answers(_ item: Item) -> some View {
        let layout = Platform.isMobile ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            if Platform.isMobile, let guess = item.guess {
                yesButton(guess)
            }
            Menu {
                otherChoices(item)
            } label: {
                HStack(spacing: 6) {
                    Text(item.guess == nil ? String(localized: "Name wählen", comment: "naming a voice: button that opens the list of people") : String(localized: "Jemand anderes", comment: "naming a voice: it is not the person the app guessed"))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(Platform.isMobile ? .body.weight(.semibold) : .uiMedium)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: Platform.isMobile ? 50 : 32)
                .background(Capsule().fill(Theme.control))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("naming.other")
            if !Platform.isMobile, let guess = item.guess {
                yesButton(guess)
            }
        }
    }

    private func yesButton(_ guess: Choice) -> some View {
        Button {
            choose(guess)
        } label: {
            Text("Ja, das ist \(guess.firstName)", comment: "naming a voice: confirm the person the app guessed")
                .font(Platform.isMobile ? .body.weight(.semibold) : .uiSemibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: Platform.isMobile ? 50 : 32)
                .background(Capsule().fill(Theme.accentFill))
                .contentShape(Capsule())
        }
        .buttonStyle(PlainPressStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("naming.yes")
    }

    /// Everyone else it could be: the app's other guesses, the invitees, everyone known; a new name; you; nobody.
    @ViewBuilder
    private func otherChoices(_ item: Item) -> some View {
        let others = item.guess == nil ? item.choices : Array(item.choices.dropFirst())
        let guesses = others.filter(\.isGuess)
        let rest = others.filter { !$0.isGuess }
        if !guesses.isEmpty {
            Section(String(localized: "Vermutlich", comment: "section title over the person a voice probably is")) {
                ForEach(guesses) { choice in choiceButton(choice) }
            }
        }
        if !rest.isEmpty {
            if item.guess == nil && guesses.isEmpty {
                restButtons(rest)
            } else {
                Section(String(localized: "Andere", comment: "section title over the other people a voice could be")) {
                    restButtons(rest)
                }
            }
        }
        Divider()
        Button("Neue Person …", systemImage: "person.badge.plus") {
            addingPerson = true
            focus = .name
        }
        Button("Das bin ich", systemImage: "person.crop.circle") {
            model.assignToMe(item.speaker)
            next(named: true)
        }
        Button("Niemand Bestimmtes", systemImage: "person.slash") {
            model.ignoreVoice(item.speaker)
            next(named: false)
        }
    }

    @ViewBuilder
    private func restButtons(_ rest: [Choice]) -> some View {
        ForEach(rest.prefix(12)) { choice in choiceButton(choice) }
        if rest.count > 12 {
            Menu("Weitere …") {
                ForEach(rest.dropFirst(12)) { choice in choiceButton(choice) }
            }
        }
    }

    private func choiceButton(_ choice: Choice) -> some View {
        Button {
            choose(choice)
        } label: {
            Text(choice.name)
            if let detail = choice.detail { Text(detail) }
        }
    }

    private var newPersonField: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
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
        }
    }

    private var footer: some View {
        HStack {
            Button("Überspringen") { advance() }
                .help("Diese Stimme überspringen (→)")
            Spacer()
            Button(String(localized: "Später", comment: "naming voices: stop for now, the rest waits")) { close() }
                .keyboardShortcut(.cancelAction)
                .help("Die übrigen Stimmen warten im Eingang (Esc)")
        }
        .buttonStyle(PlainPressStyle())
        .font(Platform.isMobile ? .body : .ui)
        .foregroundStyle(Theme.accent)
        .frame(minHeight: Platform.isMobile ? 44 : 24)
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(Theme.positive)
            Text(named > 0 ? "Alle Stimmen haben einen Namen." : "Keine Stimme wartet auf einen Namen.")
                .font(.uiSemibold)
            Text("Die App erkennt die Stimmen jetzt auch in anderen Meetings und sortiert dort nach.")
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Fertig") { close() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    /// How far the voice sample has played.
    private func sampleProgress(_ item: Item) -> Double {
        guard isPlaying, let start = item.speaker.sampleStart, let end = item.speaker.sampleEnd, end > start else { return 0 }
        return (model.player.currentTime - start) / (end - start)
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
        addingPerson = false
        newName = ""
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
