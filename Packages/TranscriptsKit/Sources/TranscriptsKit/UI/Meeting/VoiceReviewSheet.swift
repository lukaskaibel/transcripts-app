import SwiftUI

/// What the app isn't sure about in one speaker's lines.
struct SpeakerDoubts: Equatable {
    /// A group of the speaker's lines that sounds like someone else.
    struct Voice: Equatable, Identifiable {
        /// "Stimme 2": the speaker's own voice is the first.
        var number: Int
        var group: SpeakerVoices.Group
        /// Its lines still in question, in order.
        var lines: [Segment]
        var id: String { group.id }
    }

    /// The speaker's own voice, to compare with.
    var main: SpeakerVoices.Group?
    var voices: [Voice] = []
    /// Lines the app moved to the speaker because they sound like them.
    var moved: [Segment] = []

    var isEmpty: Bool { voices.isEmpty && moved.isEmpty }
}

/// Going through what the app isn't sure about in one speaker's lines, laid out like a song's lyrics: the lines in
/// question bold and in their colour among the grey lines around them. Played, they come one after another from
/// the speaker's own channel only, cut to where the voice is; the line heard lights up and stays in view. Who said
/// them is one click below.
struct VoiceReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let detail: MeetingDetail
    let speaker: MeetingSpeaker
    let doubts: SpeakerDoubts

    @State private var selection: String?
    /// Lines answered here: hidden at once, before the speaker's voices are worked out again.
    @State private var answered: Set<Int64> = []
    /// Where in each line its voice is.
    @State private var spans: [Int64: ClosedRange<Double>] = [:]
    @State private var startedPlayback = false

    /// One set of lines in question.
    fileprivate struct Doubt: Identifiable {
        enum Kind { case voice(SpeakerDoubts.Voice), moved }
        var id: String
        var kind: Kind
        var lines: [Segment]
        var color: Color
        var ids: [Int64] { lines.compactMap(\.id) }
    }

    private var open: [Doubt] {
        var result: [Doubt] = doubts.voices.enumerated().compactMap { index, voice in
            let lines = voice.lines.filter { !answered.contains($0.id ?? -1) }
            guard !lines.isEmpty else { return nil }
            return Doubt(id: voice.id, kind: .voice(voice), lines: lines, color: Theme.doubtColors[index % Theme.doubtColors.count])
        }
        let moved = doubts.moved.filter { !answered.contains($0.id ?? -1) }
        if !moved.isEmpty {
            result.append(Doubt(id: "moved", kind: .moved, lines: moved, color: Theme.movedColor))
        }
        return result
    }

    var body: some View {
        let open = self.open
        let current = open.first { $0.id == selection } ?? open.first
        VStack(alignment: .leading, spacing: 0) {
            header
            if let current {
                if open.count > 1 { tabs(open, current: current) }
                explanation(current)
                Divider()
                lyrics(current)
                Divider()
                answers(current)
            } else {
                done
            }
        }
        .foregroundStyle(Theme.text)
        #if os(macOS)
        .frame(width: 620, height: 680)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task(id: doubts.voices.flatMap(\.lines).compactMap(\.id) + doubts.moved.compactMap(\.id)) { await measure() }
        .onDisappear {
            if startedPlayback { model.player.stop() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Avatar(kind: detail.avatarKind(for: speaker.key), size: Platform.isMobile ? 40 : 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wer spricht hier?", comment: "voice review: title")
                    .font(Platform.isMobile ? .title2.bold() : .system(size: 20, weight: .bold))
                Text(verbatim: "\(detail.settledName(for: speaker.key)) · \(detail.meeting.title)")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Fertig") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.top, Platform.isMobile ? 24 : 20)
        .padding(.bottom, 14)
    }

    private func tabs(_ open: [Doubt], current: Doubt) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(open) { doubt in
                    let on = doubt.id == current.id
                    Button {
                        if model.player.isPlaying, startedPlayback { model.player.pause() }
                        selection = doubt.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(doubt.color).frame(width: 8, height: 8)
                            Text(title(of: doubt)).font(.uiMedium)
                            Text(TimeFormat.duration(speech(of: doubt.lines)))
                                .font(.small)
                                .foregroundStyle(on ? doubt.color.opacity(0.8) : Theme.textTertiary)
                        }
                        .foregroundStyle(on ? doubt.color : Theme.textBody)
                        .padding(.horizontal, 12)
                        .frame(minHeight: Platform.isMobile ? 36 : 28)
                        .background(Capsule().fill(on ? doubt.color.opacity(0.15) : Theme.control))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PlainPressStyle())
                    .focusEffectDisabled()
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .debugFrame("review.tab.\(open.firstIndex { $0.id == doubt.id } ?? 0)")
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 10)
    }

    private func title(of doubt: Doubt) -> String {
        switch doubt.kind {
        case .voice(let voice): String(localized: "Stimme \(voice.number)")
        case .moved: String(localized: "Verschoben", comment: "voice review: the lines the app moved to this speaker")
        }
    }

    /// Why these lines are in question, and whom they sound like.
    private func explanation(_ doubt: Doubt) -> some View {
        let name = detail.settledName(for: speaker.key)
        var text: String
        switch doubt.kind {
        case .voice(let voice):
            text = speaker.isMe
                ? String(localized: "Diese Zeilen kamen über dein Mikrofon, klingen aber nicht wie du.", comment: "voice review: lines on the user's microphone that sound like someone else")
                : String(localized: "Diese Zeilen stehen bei \(name), klingen aber anders.", comment: "voice review: lines with a speaker that sound unlike them")
            if let match = match(for: voice) {
                text += " " + (match.isMe
                    ? String(localized: "Sie klingen nach dir.", comment: "voice review: the lines sound like the user")
                    : String(localized: "Sie klingen nach \(match.name).", comment: "voice review: the lines sound like this person"))
            }
            let from = origins(of: doubt.lines).map { detail.settledName(for: $0) }
            if !from.isEmpty {
                text += " " + String(localized: "Vorher bei \(from.joined(separator: ", ")).", comment: "voice review: the speakers the moved lines were with before")
            }
        case .moved:
            // The app moves lines to a voice it only guesses at too: then they sound like whom it guesses.
            let soundsLike = speaker.personId == nil ? detail.guesses(for: speaker).first?.name ?? name : name
            text = String(localized: "Die App hat diese Zeilen hierher verschoben, weil sie nach \(soundsLike) klingen.", comment: "voice review: lines the app moved to this speaker")
            let from = origins(of: doubt.lines).map { detail.settledName(for: $0) }
            if !from.isEmpty {
                text += " " + String(localized: "Vorher bei \(from.joined(separator: ", ")).", comment: "voice review: the speakers the moved lines were with before")
            }
        }
        return Text(text)
            .font(Platform.isMobile ? .subheadline : .ui)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
    }

    // MARK: Lyrics

    fileprivate struct Row: Identifiable {
        enum Kind {
            /// A line around the ones in question, by whoever said it; `before` the one in question or after it.
            case context(Segment, before: Bool)
            case line(Segment, index: Int)
            /// Time passes between two stretches.
            case gap
        }

        var id: String
        var kind: Kind
    }

    /// The lines in question in transcript order, each with the lines just before and after it, unless the
    /// conversation had moved on by then.
    private func rows(for doubt: Doubt) -> [Row] {
        let all = detail.segments
        let inQuestion = Set(doubt.ids)
        var shown = IndexSet()
        for index in all.indices where all[index].id.map(inQuestion.contains) == true {
            shown.insert(index)
            if index > 0, all[index].start - all[index - 1].end < 30 { shown.insert(index - 1) }
            if index + 1 < all.count, all[index + 1].start - all[index].end < 30 { shown.insert(index + 1) }
        }
        var rows: [Row] = []
        var previous: Int?
        for index in shown {
            if let previous, index > previous + 1 { rows.append(Row(id: "gap-\(index)", kind: .gap)) }
            let line = all[index]
            if let id = line.id, inQuestion.contains(id), let number = doubt.lines.firstIndex(where: { $0.id == id }) {
                rows.append(Row(id: "line-\(id)", kind: .line(line, index: number)))
            } else {
                let before = index + 1 < all.count && all[index + 1].id.map(inQuestion.contains) == true
                rows.append(Row(id: "context-\(line.id ?? Int64(index))", kind: .context(line, before: before)))
            }
            previous = index
        }
        return rows
    }

    private func lyrics(_ doubt: Doubt) -> some View {
        let playing = playingLine(in: doubt)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows(for: doubt)) { row in
                        switch row.kind {
                        case .context(let line, let before):
                            contextRow(line, before: before)
                        case .line(let line, let index):
                            LyricLine(
                                line: line, color: doubt.color, look: playing == nil ? .still : (playing == line.id ? .playing : .dimmed),
                                canPlay: hasAudio, play: { play(doubt, from: index) }
                            ) {
                                lineMenu(line, in: doubt)
                            }
                            .id(row.id)
                        case .gap:
                            Text(verbatim: "⋯")
                                .font(.ui)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.leading, Self.gutter + 14)
                                .padding(.vertical, 4)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .background(Theme.panel)
            .onChange(of: playing) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo("line-\(id)", anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
    }

    static let gutter: CGFloat = Platform.isMobile ? 44 : 40

    private func contextRow(_ line: Segment, before: Bool) -> some View {
        var text = AttributedString(detail.settledName(for: line.speakerKey))
        text.font = .reading.weight(.semibold)
        text += AttributedString("  " + line.text)
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(TimeFormat.clock(line.start))
                .font(.tiny)
                .monospacedDigit()
                .frame(width: Self.gutter, alignment: .trailing)
            Text(text)
                .font(.reading)
                .lineLimit(2)
                .truncationMode(before ? .head : .tail)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.vertical, 5)
    }

    /// What can be said about one line on its own.
    @ViewBuilder
    private func lineMenu(_ line: Segment, in doubt: Doubt) -> some View {
        if let id = line.id {
            Menu(String(localized: "Nur diese Zeile", comment: "voice review: give one line to someone")) {
                PersonChoices(attendees: detail.meeting.attendees) { personId in
                    answer([id]) { model.assignLines([id], in: detail.meeting.id, to: personId) }
                } newPerson: {
                    askNewPerson(for: [id])
                }
            }
            Button(String(localized: "Gehört zu \(detail.settledName(for: speaker.key))", comment: "voice review: this line belongs with the speaker it is with"), systemImage: "checkmark") {
                answer([id]) { model.keepLines([id]) }
            }
            if case .voice = doubt.kind {
                Button("Nicht für die Stimme verwenden", systemImage: "nosign") {
                    answer([id]) { model.setLinesIgnored([id], ignored: true) }
                }
            }
        }
    }

    // MARK: Answers

    private func answers(_ doubt: Doubt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                playButton(doubt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playingLine(in: doubt).flatMap { id in doubt.lines.firstIndex { $0.id == id } }.map {
                        String(localized: "Zeile \($0 + 1) von \(doubt.lines.count)", comment: "voice review: which of the lines in question is playing")
                    } ?? String(localized: "Anhören"))
                    .font(.uiMedium)
                    .monospacedDigit()
                    if let hint = channelHint(doubt) {
                        Text(hint).font(.small).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                if let main = doubts.main, hasAudio {
                    Button {
                        play([main.example], from: 0, limit: 12)
                    } label: {
                        Label(speaker.isMe ? String(localized: "So klingst du", comment: "voice review: play the user's own voice to compare") : String(localized: "So klingt \(detail.settledName(for: speaker.key))", comment: "voice review: play the speaker's own voice to compare"), systemImage: "play.fill")
                            .font(.small.weight(.medium))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(String(localized: "Zum Vergleich: die längste Zeile der Stimme", comment: "voice review: help for the compare button"))
                }
            }
            Text("Wer sagt diese Zeilen?", comment: "voice review: the question the buttons answer")
                .font(.uiSemibold)
                .padding(.top, 4)
            FlowRow {
                ForEach(choices(for: doubt)) { choice in
                    Button {
                        answer(choice.ids, choice.action)
                    } label: {
                        HStack(spacing: 6) {
                            Avatar(kind: choice.avatar, size: Platform.isMobile ? 22 : 18)
                            Text(choice.name).font(.uiMedium).lineLimit(1)
                        }
                        .foregroundStyle(choice.suggested ? doubt.color : Theme.textBody)
                        .padding(.leading, 5)
                        .padding(.trailing, 12)
                        .frame(minHeight: Platform.isMobile ? 36 : 30)
                        .background(Capsule().fill(choice.suggested ? doubt.color.opacity(0.15) : Theme.control))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PlainPressStyle())
                    .focusEffectDisabled()
                    .help(choice.help)
                    .debugFrame("review.choice.\(choice.id)")
                }
                someoneElse(doubt)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, Platform.isMobile ? 12 : 18)
    }

    private func playButton(_ doubt: Doubt) -> some View {
        let playing = playingLine(in: doubt) != nil
        return Button {
            if playing {
                model.player.pause()
            } else {
                play(doubt, from: resumeIndex(in: doubt))
            }
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: Platform.isMobile ? 16 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Platform.isMobile ? 44 : 36, height: Platform.isMobile ? 44 : 36)
                .background(Circle().fill(doubt.color))
                .contentShape(Circle())
        }
        .buttonStyle(PlainPressStyle())
        .keyboardShortcut(.space, modifiers: [])
        .debugFrame("review.play")
        .disabled(!hasAudio)
        .opacity(hasAudio ? 1 : 0.4)
        .help(playing ? String(localized: "Pause") : String(localized: "Die Zeilen nacheinander anhören", comment: "voice review: play button help"))
        .accessibilityLabel(playing ? String(localized: "Pause") : String(localized: "Anhören"))
    }

    /// A button that says who said the lines.
    fileprivate struct Choice: Identifiable {
        var id: String
        var name: String
        var avatar: Avatar.Kind
        /// The lines it answers for.
        var ids: [Int64]
        /// The person the lines sound like.
        var suggested = false
        var help: String
        var action: () -> Void
    }

    /// The speaker the lines are with, where the app moved them from, and the others in the meeting: whom the lines
    /// sound like first.
    private func choices(for doubt: Doubt) -> [Choice] {
        let meetingId = detail.meeting.id
        let ids = doubt.ids
        let name = detail.settledName(for: speaker.key)
        var result = [Choice(
            id: "keep", name: speaker.isMe ? String(localized: "Ich", comment: "voice review: button, the lines are the user's") : name,
            avatar: detail.avatarKind(for: speaker.key), ids: ids,
            help: String(localized: "Die Zeilen bleiben bei \(name)", comment: "voice review: help for keeping the lines where they are")
        ) { model.keepLines(ids) }]
        var named: Set<String> = Set([speaker.personId].compactMap { $0 })
        // Back where the app took them from: only the lines it moved.
        for origin in origins(of: doubt.lines) {
            let lines = doubt.lines.filter { $0.placement == .app && $0.movedFromKey == origin }.compactMap(\.id)
            let originName = detail.settledName(for: origin)
            if let person = detail.speaker(for: origin)?.personId { named.insert(person) }
            result.append(Choice(
                id: "back-\(origin)", name: originName, avatar: detail.avatarKind(for: origin), ids: lines,
                help: String(localized: "Zurück zu \(originName)", comment: "voice review: help for sending moved lines back")
            ) { model.returnMovedLines(lines, in: meetingId) })
        }
        // You last: lines are rarely yours on someone else's channel.
        for other in detail.speakers.sorted(by: { ($0.isMe ? 1 : 0, -$0.talkTime) < ($1.isMe ? 1 : 0, -$1.talkTime) }) where other.key != speaker.key {
            guard let personId = other.personId, let person = detail.people[personId], !named.contains(personId) else { continue }
            named.insert(personId)
            result.append(Choice(
                id: personId, name: person.isMe ? String(localized: "Ich", comment: "voice review: button, the lines are the user's") : person.name,
                avatar: detail.avatarKind(for: other.key), ids: ids,
                help: String(localized: "Die Zeilen \(person.name) geben", comment: "voice review: help for giving the lines to someone")
            ) { model.assignLines(ids, in: meetingId, to: personId) })
        }
        guard case .voice(let voice) = doubt.kind, let match = match(for: voice) else { return result }
        if let index = result.firstIndex(where: { $0.id == match.personId || ($0.id == "keep" && speaker.personId == match.personId) }) {
            var choice = result.remove(at: index)
            choice.suggested = true
            result.insert(choice, at: 0)
        } else if let person = model.person(match.personId) {
            result.insert(Choice(
                id: person.id, name: person.isMe ? String(localized: "Ich", comment: "voice review: button, the lines are the user's") : person.name,
                avatar: person.isMe ? .me(name: person.name) : .person(name: person.name), ids: ids, suggested: true,
                help: String(localized: "Die Zeilen \(person.name) geben", comment: "voice review: help for giving the lines to someone")
            ) { model.assignLines(ids, in: meetingId, to: person.id) }, at: 0)
        }
        return result
    }

    /// Everyone else, a new person, a voice of its own, or not counting the lines at all.
    private func someoneElse(_ doubt: Doubt) -> some View {
        let ids = doubt.ids
        return Menu {
            Section(String(localized: "Jemand anderes", comment: "voice review: menu of everyone else")) {
                PersonChoices(attendees: detail.meeting.attendees, excluding: speaker.personId) { personId in
                    answer(ids) { model.assignLines(ids, in: detail.meeting.id, to: personId) }
                } newPerson: {
                    askNewPerson(for: ids)
                }
            }
            Divider()
            Button("Als eigene Stimme abtrennen", systemImage: "scissors") {
                answer(ids) { model.separateLines(ids, in: detail.meeting.id) }
            }
            if case .voice = doubt.kind {
                Button("Nicht für die Stimme verwenden", systemImage: "nosign") {
                    answer(ids) { model.setLinesIgnored(ids, ignored: true) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("Jemand anderes", comment: "voice review: menu of everyone else").font(.uiMedium)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, 12)
            .frame(minHeight: Platform.isMobile ? 36 : 30)
            .background(Capsule().fill(Theme.control))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.positive)
            Text("Alles zugeordnet", comment: "voice review: nothing left in question")
                .font(.pageHeading)
            Text("Die App merkt sich, wer was gesagt hat.", comment: "voice review: after everything is answered")
                .font(.ui)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: Doing

    private func answer(_ ids: [Int64], _ action: () -> Void) {
        if startedPlayback { model.player.pause() }
        withAnimation(Theme.spring) { answered.formUnion(ids) }
        action()
    }

    private func askNewPerson(for ids: [Int64]) {
        NamePrompt.ask(title: String(localized: "Wer ist das?"), message: String(localized: "Diese Zeilen werden der Person zugeordnet und ihre Stimme gemerkt.")) { name in
            answer(ids) { model.assignLines(ids, in: detail.meeting.id, toNewPersonNamed: name) }
        }
    }

    private func play(_ doubt: Doubt, from index: Int) {
        play(doubt.lines, from: index)
    }

    /// Plays the lines from `index` on, one after another, each where its voice is, from its own channel only.
    private func play(_ lines: [Segment], from index: Int, limit: Double? = nil) {
        guard lines.indices.contains(index) else { return }
        var stretches: [ClosedRange<Double>] = []
        for line in lines[index...].sorted(by: { $0.start < $1.start }) {
            var span = line.id.flatMap { spans[$0] } ?? line.start...line.end
            if let limit, span.upperBound - span.lowerBound > limit { span = span.lowerBound...span.lowerBound + limit }
            if let last = stretches.last, span.lowerBound <= last.upperBound {
                stretches[stretches.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                stretches.append(span)
            }
        }
        let channels = Set(lines.map(\.channel))
        startedPlayback = true
        Task { await model.player.play(meetingId: detail.meeting.id, stretches: stretches, only: channels.count == 1 ? channels.first : nil) }
    }

    /// The line of the doubt the player is in, while it plays.
    private func playingLine(in doubt: Doubt) -> Int64? {
        let player = model.player
        guard player.isPlaying, player.meetingId == detail.meeting.id else { return nil }
        return line(at: player.currentTime, in: doubt)
    }

    private func line(at time: Double, in doubt: Doubt) -> Int64? {
        doubt.lines.first { line in
            let span = line.id.flatMap { spans[$0] } ?? line.start...line.end
            return time >= span.lowerBound - 0.05 && time < span.upperBound + 0.05
        }?.id
    }

    /// Where a paused playback of the doubt carries on: the line it stopped in, or the first.
    private func resumeIndex(in doubt: Doubt) -> Int {
        guard startedPlayback, model.player.meetingId == detail.meeting.id,
              let id = line(at: model.player.currentTime, in: doubt) else { return 0 }
        return doubt.lines.firstIndex { $0.id == id } ?? 0
    }

    /// Where the voices of the lines in question are in their audio, worked out in the background.
    private func measure() async {
        let meetingId = detail.meeting.id
        let lines = doubts.voices.flatMap(\.lines) + doubts.moved + [doubts.main?.example].compactMap { $0 }
        let measured = await Task.detached(priority: .userInitiated) {
            var result: [Int64: ClosedRange<Double>] = [:]
            for line in lines {
                guard let id = line.id,
                      let file = AppPaths.playbackAudio(for: meetingId, channel: line.channel) ?? AppPaths.existingImport(for: meetingId) else { continue }
                result[id] = AudibleSpan.of(line.start...line.end, in: file)
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        spans = measured
    }

    // MARK: Facts

    private var hasAudio: Bool { AudioArchiver.hasAudio(meetingId: detail.meeting.id) }

    /// How long the voice speaks in the lines, once measured; a line's own length runs on after its last word.
    private func speech(of lines: [Segment]) -> Double {
        lines.reduce(0) { total, line in
            let span = line.id.flatMap { spans[$0] } ?? line.start...line.end
            return total + span.upperBound - span.lowerBound
        }
    }

    /// Whom a group of lines sounds like, leaving out what this meeting taught the app.
    private func match(for voice: SpeakerDoubts.Voice) -> (personId: String, name: String, isMe: Bool)? {
        let excluded: Set<String> = speaker.isMe ? [] : Set([model.me?.id].compactMap { $0 })
        guard let best = model.voiceLibrary.rank(voice.group.centroid, excluding: excluded, without: detail.meeting.id).first,
              best.similarity >= model.settings.voiceStrictness.thresholds.suggestion,
              let person = model.person(best.personId) else { return nil }
        return (person.id, person.firstName, person.isMe)
    }

    /// The speakers moved lines came from that are still in the meeting.
    private func origins(of lines: [Segment]) -> [String] {
        Set(lines.compactMap(\.movedFromKey)).filter { detail.speaker(for: $0) != nil }.sorted()
    }

    /// Which channel plays, when the meeting has both.
    private func channelHint(_ doubt: Doubt) -> String? {
        let channels = Set(doubt.lines.map(\.channel))
        let meetingId = detail.meeting.id
        guard channels.count == 1, Channel.allCases.allSatisfy({ AppPaths.playbackAudio(for: meetingId, channel: $0) != nil }) else { return nil }
        return channels.first == .microphone
            ? String(localized: "Nur dein Mikrofon, ohne den Anruf", comment: "voice review: only the microphone channel plays")
            : String(localized: "Nur der Anruf, ohne dein Mikrofon", comment: "voice review: only the call's channel plays")
    }
}

/// One line in question, as a line of lyrics: bold in its colour, at the size of the lines around it; while the lines
/// play, lit up when it is the one heard and faded otherwise. A click plays from here, the context menu answers for this line alone.
private struct LyricLine<Actions: View>: View {
    enum Look { case still, playing, dimmed }

    let line: Segment
    let color: Color
    let look: Look
    let canPlay: Bool
    let play: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ZStack(alignment: .trailing) {
                    if look == .playing {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color)
                            .symbolEffect(.variableColor.iterative, isActive: true)
                    } else if hovering, canPlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(color)
                    } else {
                        Text(TimeFormat.clock(line.start))
                            .font(.tiny)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: VoiceReviewSheet.gutter, alignment: .trailing)
                Text(line.text)
                    .font(font)
                    .foregroundStyle(color)
                    .opacity(look == .dimmed ? 0.3 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .contextMenu { actions() }
        .animation(.easeOut(duration: 0.3), value: look)
        .help(String(localized: "Ab dieser Zeile anhören", comment: "voice review: click a line to play from it"))
        .accessibilityLabel(line.text)
        .accessibilityHint(String(localized: "Ab dieser Zeile anhören", comment: "voice review: click a line to play from it"))
    }

    /// The transcript's own size: colour and weight are what set the line apart.
    private var font: Font { .reading.weight(.bold) }
}
