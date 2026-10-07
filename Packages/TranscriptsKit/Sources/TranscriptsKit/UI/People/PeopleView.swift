import AppKit
import SwiftUI

/// Everyone the app knows by voice, and the voices that wait for a name.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: PersonStats?
    @AppStorage("showVoiceMap") private var showsMap = true
    /// The person hovered in the list, whose voice stands out on the map.
    @State private var highlighted: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Personen").font(.uiSemibold)
                Text("\(model.peopleStats.count)").foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    withAnimation(Theme.spring) { showsMap.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "circle.hexagongrid").font(.system(size: 11))
                        Text("Stimmenkarte")
                    }
                    .font(.small)
                    .foregroundStyle(showsMap ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(showsMap ? Theme.selectionFill : Theme.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .help(showsMap ? "Stimmenkarte ausblenden" : "Stimmenkarte zeigen: alle Stimmen auf einen Blick")
                .disabled(model.peopleStats.isEmpty)
            }
            .padding(.horizontal, 18)
            .frame(height: Theme.headerHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }

            if model.peopleStats.isEmpty && model.reviews.isEmpty {
                EmptyState(systemImage: "person.2", title: String(localized: "Noch niemand bekannt"), message: String(localized: "Nach dem ersten Meeting erscheinen hier die Stimmen. Benenne sie einmal, dann erkennt die App sie in künftigen Meetings wieder."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsMap {
                            VoicesOverview(highlighted: highlighted)
                                .padding(.bottom, 14)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if !model.reviews.isEmpty {
                            HStack(spacing: 8) {
                                Circle().fill(Theme.warning).frame(width: 7, height: 7)
                                Text("Zu bestätigen").font(.uiSemibold)
                                Text("\(model.reviews.count)").foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Button("Alle durchgehen") { model.startNaming() }
                                    .buttonStyle(PrimaryButtonStyle())
                                    .help("Eine Stimme nach der anderen anhören und benennen")
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
                            ForEach(model.reviews) { review in
                                ReviewRow(review: review)
                                if review.id != model.reviews.last?.id {
                                    Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.horizontal, 14)
                                }
                            }
                        }
                        knownHeader.padding(.top, model.reviews.isEmpty ? 0 : 14)
                        ForEach(model.peopleStats) { stats in
                            PersonRow(stats: stats, mapColor: showsMap && stats.voiceSamples > 0 ? VoicesOverview.color(for: stats.person.id, among: model.people) : nil) { selected = stats }
                                .onHover { inside in
                                    if inside { highlighted = stats.person.id } else if highlighted == stats.person.id { highlighted = nil }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .sheet(item: $selected) { stats in
            PersonSheet(personId: stats.person.id)
                .id(stats.person.id)
        }
        .onChange(of: model.openPersonId, initial: true) { _, personId in
            guard let personId, let stats = model.peopleStats.first(where: { $0.person.id == personId }) else { return }
            selected = stats
            model.openPersonId = nil
        }
    }

    private var knownHeader: some View {
        HStack(spacing: 0) {
            Text("Bekannt").font(.uiSemibold)
            Text("  \(model.peopleStats.count)").foregroundStyle(Theme.textTertiary)
            Spacer()
            Group {
                Text("Stimmprofil").frame(width: 110, alignment: .leading)
                Text("Meetings").frame(width: 92, alignment: .trailing)
                Text("Sprechzeit").frame(width: 96, alignment: .trailing)
                Text(String(localized: "Zuletzt", comment: "column header: when the person was last heard in a meeting")).frame(width: 100, alignment: .trailing)
            }
            .font(.smallMedium)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
    }
}

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let review: VoiceReview

    private var detailForMenu: MeetingDetail? {
        try? model.database.detail(of: review.speaker.meetingId)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if let start = review.speaker.sampleStart, let end = review.speaker.sampleEnd {
                    Task { await model.player.play(meetingId: review.speaker.meetingId, from: start, until: end) }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.2, 2])))
            }
            .buttonStyle(PlainPressStyle())
            .help("Stimmprobe anhören")
            .disabled(review.speaker.sampleStart == nil || !AudioArchiver.hasAudio(meetingId: review.speaker.meetingId))

            Button {
                model.select(review.speaker.meetingId)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(review.speaker.displayLabel).font(.uiSemibold)
                        Text("\(TimeFormat.duration(review.speaker.talkTime)) Sprache")
                            .font(.small)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text("\(review.meetingTitle) · \(TimeFormat.compactDay(review.meetingDate))")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .frame(width: 280, alignment: .leading)
            .help("Meeting öffnen")

            if guesses.count > 1 {
                // Not sure between a few: one button each.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text(String(localized: "vermutlich", comment: "before buttons with the people an unknown voice probably is")).font(.small).foregroundStyle(Theme.textTertiary)
                    ForEach(guesses) { person in
                        Button(person.name) { model.assign(review.speaker, to: person.id) }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("\(person.name) zuordnen")
                    }
                }
                Spacer(minLength: 8)
                otherMenu("Andere Person")
            } else if let name = suggestionName {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Avatar(kind: .person(name: name), size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.uiMedium).lineLimit(1)
                        if let reason = review.speaker.displayReason ?? (guesses.isEmpty ? nil : String(localized: "Stimme ähnlich", comment: "reason under a suggested name: the voice sounds like this person's")) {
                            Text(reason).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                Button("Bestätigen") {
                    if let person = guesses.first, review.speaker.suggestedPersonId == nil, review.speaker.suggestedName == nil {
                        model.assign(review.speaker, to: person.id)
                    } else {
                        model.confirmSuggestion(review.speaker)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                otherMenu("Andere Person")
            } else {
                Text("Kein Name im Gespräch gefallen").font(.small).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                otherMenu("Namen vergeben")
                Button("Ignorieren") { ignore() }
                    .buttonStyle(PlainPressStyle())
                    .font(.small)
                    .foregroundStyle(Theme.textSecondary)
                    .help("Diese Stimme nicht mehr vorschlagen")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }

    private var isPlaying: Bool {
        model.player.isPlaying && model.player.meetingId == review.speaker.meetingId && model.player.stopAt != nil
    }

    private var suggestionName: String? {
        review.suggestedPerson?.name ?? review.speaker.suggestedName ?? guesses.first?.name
    }

    private var guesses: [Person] {
        review.speaker.guesses.compactMap { model.person($0) }
    }

    private func otherMenu(_ title: LocalizedStringKey) -> some View {
        Menu {
            if let detail = detailForMenu {
                SpeakerMenuItems(detail: detail, speaker: review.speaker)
            }
        } label: {
            Text(title)
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
    }

    /// An unknown voice the user doesn't care about: keep it unnamed, but out of the review list.
    private func ignore() {
        model.ignoreVoice(review.speaker)
    }
}

struct PersonRow: View {
    let stats: PersonStats
    /// The person's colour on the voice map, while the map is shown.
    var mapColor: Color?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Avatar(kind: stats.person.isMe ? .me(name: stats.person.name) : .person(name: stats.person.name), size: 22)
                Text(stats.person.name).font(.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                if let mapColor {
                    Circle().fill(mapColor).frame(width: 7, height: 7).help("Farbe auf der Stimmenkarte")
                }
                if stats.person.isMe {
                    Chip {
                        Image(systemName: "mic").font(.system(size: 9))
                        Text("Du")
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    VoiceQualityBars(quality: stats.voiceQuality)
                    Text([String(localized: "Kein Profil"), String(localized: "schwach", comment: "voice profile quality"), String(localized: "mittel", comment: "voice profile quality"), String(localized: "gut", comment: "voice profile quality")][max(0, min(stats.voiceQuality, 3))])
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: 110, alignment: .leading)
                Text("\(stats.meetings)").frame(width: 92, alignment: .trailing)
                Text(stats.talkTime > 0 ? TimeFormat.duration(stats.talkTime) : "–").frame(width: 96, alignment: .trailing)
                Text(stats.lastSeen.map { TimeFormat.compactDay($0) } ?? "–").frame(width: 100, alignment: .trailing).lineLimit(1)
            }
            .font(.small)
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .onHover { hovering = $0 }
        .foregroundStyle(Theme.text)
    }
}

/// One person: rename, see their meetings, merge with a duplicate, forget their voice, delete.
struct PersonSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let personId: String
    @State private var name = ""
    @State private var meetings: [Meeting] = []
    @State private var confirmDelete = false
    @State private var contentHeight: CGFloat = 400

    private var stats: PersonStats? { model.peopleStats.first { $0.person.id == personId } }

    /// The screen's height less room for the window's title and the sheet's buttons.
    static var maximumContentHeight: CGFloat {
        min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 200)
    }

    var body: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Avatar(kind: stats.person.isMe ? .me(name: stats.person.name) : .person(name: stats.person.name), size: 36)
                            TextField("Name", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 18, weight: .semibold))
                                .onSubmit(save)
                        }
                        Text(summary(stats))
                            .font(.small)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 8)

                        VoiceProfileSection(person: stats.person)
                            .padding(.top, 20)

                        Text("Meetings").font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 20)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(meetings) { meeting in
                                Button {
                                    save()
                                    model.select(meeting.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(meeting.title).lineLimit(1)
                                        Spacer()
                                        Text(TimeFormat.shortDate(meeting.startedAt)).font(.small).foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .hoverFill(radius: 6)
                                }
                                .buttonStyle(PlainPressStyle())
                            }
                            if meetings.isEmpty {
                                Text("Noch keinem Meeting zugeordnet.").font(.small).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .padding(24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // As tall as the content, but never taller than the screen: the buttons below stay in reach.
                .frame(height: min(max(contentHeight, 200), Self.maximumContentHeight))

                Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                HStack(spacing: 8) {
                    if !stats.person.isMe {
                        Menu("Zusammenführen …") {
                            ForEach(model.people.filter { $0.id != personId && !$0.isMe }) { other in
                                Button(other.name) {
                                    model.merge(stats.person, into: other)
                                    dismiss()
                                }
                            }
                        }
                        .fixedSize()
                        .help("Für doppelte Einträge derselben Person")
                    }
                    Button("Stimme vergessen") { model.forgetVoice(of: stats.person) }
                        .fixedSize()
                        .disabled(stats.voiceSamples == 0)
                        .help("Die App lernt nicht mehr aus dem, was diese Person gesagt hat; die Zuordnungen in Meetings bleiben.")
                    Spacer()
                    if !stats.person.isMe {
                        Button("Löschen …", role: .destructive) { confirmDelete = true }
                            .fixedSize()
                    }
                    Button("Fertig") {
                        save()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(width: 540)
            .font(.ui)
            .foregroundStyle(Theme.text)
            .onAppear {
                name = stats.person.name
                meetings = (try? model.database.meetings(of: personId)) ?? []
            }
            .confirmationDialog("\(stats.person.name) löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) {
                    model.delete(stats.person)
                    dismiss()
                }
            } message: {
                Text("Die Stimme wird vergessen. In den Meetings wird die Person wieder zu einer unbekannten Stimme.")
            }
        }
    }

    private func save() {
        guard let stats, name != stats.person.name else { return }
        model.rename(stats.person, to: name)
    }

    private func summary(_ stats: PersonStats) -> String {
        var parts: [String] = []
        parts.append(String(localized: "\(stats.meetings) Meetings", comment: "plural: meetings"))
        if stats.talkTime > 0 { parts.append(String(localized: "\(TimeFormat.duration(stats.talkTime)) gesprochen", comment: "how long a person spoke, e.g. 42 min")) }
        parts.append(String(localized: "\(stats.voiceSamples) Stimmproben", comment: "plural: voice samples of a person"))
        if let email = stats.person.email { parts.append(email) }
        return parts.joined(separator: " · ")
    }
}
