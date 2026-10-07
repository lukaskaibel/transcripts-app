import SwiftUI

/// A person's voice as the app knows it: a map of their lines, grouped, and what to do with each group.
struct VoiceProfileSection: View {
    @Environment(AppModel.self) private var model
    let person: Person

    private var profile: VoiceProfile? { model.voiceLibrary.profiles[person.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stimmprofil").font(.smallSemibold).foregroundStyle(Theme.textSecondary)
                Spacer()
                if let profile, profile.hasVoice {
                    Text(profile.meetingCount == 0 ? TimeFormat.duration(profile.speech) : "\(profile.meetingCount == 1 ? "1 Meeting" : "\(profile.meetingCount) Meetings") · \(TimeFormat.duration(profile.speech))")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if let profile, !profile.samples.isEmpty {
                VoiceMap(profile: profile, color: color(for:))
                    .frame(height: 150)
                    .padding(.top, 8)
                if let split = profile.possibleSplit {
                    SplitHint(first: name(of: split.0), second: name(of: split.1))
                        .padding(.top, 10)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(profile.groups.filter(\.isTrusted)) { group in
                        VoiceGroupRow(profile: profile, group: group, title: name(of: group.id), color: color(for: group.id))
                    }
                    let outliers = profile.groups.filter { !$0.isTrusted }
                    if !outliers.isEmpty || !profile.strays.isEmpty {
                        OutlierRows(profile: profile, groups: outliers)
                    }
                    if !profile.ignored.isEmpty {
                        IgnoredRow(profile: profile)
                    }
                }
                .padding(.top, 8)
            } else {
                Text(person.isMe
                    ? "Deine Stimme lernt die App aus deinem Mikrofon, sobald du in einem Meeting gesprochen hast."
                    : "Noch keine Stimme. Ordne \(person.firstName) in einem Meeting zu, dann erkennt die App die Stimme wieder.")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private func name(of groupId: Int) -> String {
        guard let profile, let group = profile.groups.first(where: { $0.id == groupId }) else { return "Stimme" }
        guard group.isTrusted else { return "Ausreißer" }
        let trusted = profile.groups.filter(\.isTrusted)
        guard trusted.count > 1, let index = trusted.firstIndex(where: { $0.id == groupId }) else { return "Stimme" }
        return "Stimme \(index + 1)"
    }

    private func color(for groupId: Int) -> Color {
        guard let profile, let group = profile.groups.first(where: { $0.id == groupId }) else { return Theme.textTertiary }
        guard group.isTrusted else { return Theme.warning }
        let trusted = profile.groups.filter(\.isTrusted)
        let index = trusted.firstIndex { $0.id == groupId } ?? 0
        if index == 0 { return person.isMe ? Theme.accent : Theme.color(for: person.name) }
        return Theme.color(for: "\(person.name) \(index)")
    }
}

/// Every line of a person as a dot, placed so that lines that sound alike lie close together. Lines of the
/// same voice group share a colour; strays are rings, lines left out are faint.
struct VoiceMap: View {
    let profile: VoiceProfile
    let color: (Int) -> Color

    private struct Dot {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var color: Color
        var hollow: Bool
        var faint: Bool
    }

    private var dots: [Dot] {
        let samples = profile.samples
        guard !samples.isEmpty else { return [] }
        var groupOf: [Int: Int] = [:]
        for group in profile.groups {
            for member in group.members { groupOf[member] = group.id }
        }
        let ignored = Set(profile.ignored)
        // Laid out by the person's voices; strays and left-out lines are placed around them.
        let trusted = Set(profile.groups.filter(\.isTrusted).map(\.id))
        let points = VoiceMath.projection(samples.map(\.embedding), fitting: samples.indices.filter { groupOf[$0].map(trusted.contains) ?? false })
        return samples.indices.map { index in
            let radius = CGFloat(2 + min(samples[index].duration, 20) / 20 * 3.5)
            let group = groupOf[index]
            return Dot(
                x: CGFloat(points[index].x), y: CGFloat(points[index].y), radius: radius,
                color: ignored.contains(index) ? Theme.textTertiary : (group.map(color) ?? Theme.warning),
                hollow: group == nil || ignored.contains(index), faint: ignored.contains(index)
            )
        }
        // Small dots on top, so a long line never hides a short one.
        .sorted { $0.radius > $1.radius }
    }

    var body: some View {
        let dots = dots
        Canvas { context, size in
            let inset: CGFloat = 10
            let width = size.width - 2 * inset
            let height = size.height - 2 * inset
            for dot in dots {
                let center = CGPoint(x: inset + (dot.x + 1) / 2 * width, y: inset + (dot.y + 1) / 2 * height)
                let rect = CGRect(x: center.x - dot.radius, y: center.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2)
                let path = Path(ellipseIn: rect)
                if dot.hollow {
                    context.stroke(path, with: .color(dot.color.opacity(dot.faint ? 0.45 : 0.9)), lineWidth: 1.2)
                } else {
                    context.fill(path, with: .color(dot.color.opacity(0.78)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rowSeparator, lineWidth: 1))
        .accessibilityLabel("Karte der Stimmproben: \(profile.samples.count) Zeilen in \(profile.groups.filter(\.isTrusted).count) Stimmen")
    }
}

/// "Two strong voices under one name": maybe two people.
private struct SplitHint: View {
    let first: String
    let second: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(Theme.warning).padding(.top, 1)
            Text("\(first) und \(second) klingen deutlich verschieden. Wenn das zwei Personen sind, gib eine davon an die richtige weiter.")
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.1)))
    }
}

/// One voice group of a person: listen to it, see where it comes from, give it to someone else.
private struct VoiceGroupRow: View {
    @Environment(AppModel.self) private var model
    let profile: VoiceProfile
    let group: VoiceProfile.Group
    let title: String
    let color: Color

    private var lines: [VoiceSample] { group.members.map { profile.samples[$0] } }

    private var example: VoiceSample? {
        lines.filter { $0.meetingId != nil && $0.start != nil && $0.source != .legacy }.max { $0.duration < $1.duration }
    }

    /// Someone else this group sounds like, which hints that it is theirs.
    private var soundsLike: Person? {
        guard let best = model.voiceLibrary.rank(group.centroid, excluding: [profile.personId]).first,
              best.similarity >= model.settings.voiceStrictness.thresholds.suggestion else { return nil }
        return model.person(best.personId)
    }

    var body: some View {
        HStack(spacing: 10) {
            PlayDot(sample: example)
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.uiMedium)
                    if let soundsLike {
                        Text("klingt wie \(soundsLike.isMe ? "dir" : soundsLike.name)").font(.tiny).foregroundStyle(Theme.warning)
                    } else if !group.isTrusted {
                        Text("passt nicht zum Rest").font(.tiny).foregroundStyle(Theme.warning)
                    }
                }
                Text(detail).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if let soundsLike {
                Button("Zu \(soundsLike.isMe ? "dir" : soundsLike.firstName)") { model.move(group, of: profile, to: soundsLike.id) }
                    .buttonStyle(PlainPressStyle())
                    .font(.small.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .help("Diese Zeilen \(soundsLike.name) zuordnen, in jedem Meeting")
            }
            Menu {
                PersonChoices(excluding: profile.personId) { personId in
                    model.move(group, of: profile, to: personId)
                } newPerson: {
                    if let name = NamePrompt.ask(title: "Wem gehört diese Stimme?", message: "Die Zeilen dieser Gruppe werden in allen Meetings dieser Person zugeordnet.") {
                        model.move(group, of: profile, toNewPersonNamed: name)
                    }
                }
                Divider()
                Button("Nicht verwenden", systemImage: "nosign") { model.setIgnored(group, of: profile, ignored: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Gehört jemand anderem, oder nicht verwenden")
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 40)
    }

    private var detail: String {
        var parts = [lines.count == 1 ? "1 Zeile" : "\(lines.count) Zeilen", TimeFormat.duration(group.speech + group.recognizedSpeech)]
        if !group.meetings.isEmpty { parts.append(group.meetings.count == 1 ? "1 Meeting" : "\(group.meetings.count) Meetings") }
        if group.recognizedSpeech > 0 { parts.append("\(TimeFormat.duration(group.recognizedSpeech)) davon erkannt") }
        if let last = group.lastHeard { parts.append("zuletzt \(TimeFormat.compactDay(last))") }
        return parts.joined(separator: " · ")
    }
}

/// Everything that fits none of the person's voices, folded into one row: small groups that sound unlike
/// the rest, and single lines. Open, each group can be played and given to whom it sounds like.
private struct OutlierRows: View {
    @Environment(AppModel.self) private var model
    let profile: VoiceProfile
    let groups: [VoiceProfile.Group]
    @State private var open = false

    private var lineCount: Int { groups.reduce(0) { $0 + $1.members.count } + profile.strays.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Theme.quick) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 22, height: 22)
                    Circle().strokeBorder(Theme.warning, lineWidth: 1.2).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ausreißer").font(.uiMedium)
                        Text(summary)
                            .font(.small)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .disabled(groups.isEmpty)
            if open {
                ForEach(groups.prefix(30)) { group in
                    VoiceGroupRow(profile: profile, group: group, title: group.members.count == 1 ? "Einzelne Zeile" : "\(group.members.count) Zeilen", color: Theme.warning)
                        .padding(.leading, 16)
                }
                if groups.count > 30 {
                    Text("und \(groups.count - 30) weitere").font(.small).foregroundStyle(Theme.textTertiary).padding(.leading, 50)
                }
            }
        }
    }

    private var summary: String {
        var text = lineCount == 1 ? "1 Zeile passt zu keiner Stimme und zählt nicht" : "\(lineCount) Zeilen passen zu keiner Stimme und zählen nicht"
        let threshold = model.settings.voiceStrictness.thresholds.suggestion
        let matching = groups.filter { group in
            (model.voiceLibrary.rank(group.centroid, excluding: [profile.personId]).first?.similarity ?? 0) >= threshold
        }.count
        if matching > 0 { text += " · \(matching) klingen wie jemand anderes" }
        return text
    }
}

/// Lines the user left out, with the way back.
private struct IgnoredRow: View {
    @Environment(AppModel.self) private var model
    let profile: VoiceProfile

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 22, height: 22)
            Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.2).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nicht verwendet").font(.uiMedium)
                Text(profile.ignored.count == 1 ? "1 Zeile" : "\(profile.ignored.count) Zeilen").font(.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 6)
            Button("Wieder verwenden") {
                model.setLinesIgnored(profile.ignored.compactMap { profile.samples[$0].segmentId }, ignored: false)
            }
            .buttonStyle(PlainPressStyle())
            .font(.small)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 36)
    }
}

/// Plays one line of a voice.
struct PlayDot: View {
    @Environment(AppModel.self) private var model
    var meetingId: String?
    var start: Double?
    var end: Double?

    init(sample: VoiceSample?) {
        meetingId = sample?.meetingId
        start = sample?.start
        end = sample.flatMap { sample in sample.start.map { $0 + min(sample.duration, 12) } }
    }

    init(meetingId: String, start: Double, end: Double) {
        self.meetingId = meetingId
        self.start = start
        self.end = end
    }

    private var playable: Bool {
        guard let meetingId, start != nil else { return false }
        return AudioArchiver.hasAudio(meetingId: meetingId)
    }

    private var isPlaying: Bool {
        model.player.isPlaying && model.player.meetingId == meetingId && model.player.stopAt == end && end != nil
    }

    var body: some View {
        Button {
            guard let meetingId, let start, let end else { return }
            if isPlaying {
                model.player.toggle()
            } else {
                Task { await model.player.play(meetingId: meetingId, from: start, until: end) }
            }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 8))
                .foregroundStyle(playable ? Theme.textSecondary : Theme.textTertiary.opacity(0.5))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.2, 2])))
        }
        .buttonStyle(PlainPressStyle())
        .disabled(!playable)
        .help("Anhören")
    }
}

/// The people a voice can be given to: the meeting's invitees first, then everyone known, a new person, the user.
struct PersonChoices: View {
    @Environment(AppModel.self) private var model
    var attendees: [Attendee] = []
    var excluding: String? = nil
    var includeMe = true
    let choose: (String) -> Void
    let newPerson: () -> Void

    var body: some View {
        let invited = attendees.filter { attendee in !model.people.contains { matches(attendee, $0) && $0.id == excluding } }
        if !invited.isEmpty {
            Section("Eingeladen") {
                ForEach(invited, id: \.name) { attendee in
                    Button(attendee.name) {
                        if let person = model.people.first(where: { !$0.isMe && matches(attendee, $0) }) {
                            choose(person.id)
                        } else if let person = try? model.database.person(named: attendee.name, email: attendee.email) {
                            choose(person.id)
                        }
                    }
                }
            }
        }
        let known = model.people.filter { person in
            !person.isMe && person.id != excluding && !invited.contains { matches($0, person) }
        }
        if !known.isEmpty {
            Section("Bekannt") {
                ForEach(known) { person in
                    Button(person.name) { choose(person.id) }
                }
            }
        }
        Button("Neue Person …", systemImage: "person.badge.plus") { newPerson() }
        if includeMe, let me = model.me, me.id != excluding {
            Button("Das bin ich", systemImage: "person.crop.circle") { choose(me.id) }
        }
    }

    private func matches(_ attendee: Attendee, _ person: Person) -> Bool {
        if let email = attendee.email?.lowercased(), let personEmail = person.email?.lowercased(), email == personEmail { return true }
        return attendee.name.lowercased() == person.name.lowercased()
    }
}

/// Asks for a name with a small panel.
enum NamePrompt {
    @MainActor
    static func ask(title: String, message: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
