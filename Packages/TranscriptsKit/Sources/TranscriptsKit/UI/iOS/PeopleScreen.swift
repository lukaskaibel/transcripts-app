#if os(iOS)
import SwiftUI

/// Everyone the app knows by voice and the voices that wait for a name, as on the Mac, with the voice map on top.
struct PeopleScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide
    @AppStorage("showVoiceMap") private var showsMap = true
    @State private var allVoices = false

    /// A few of the voices that wait, so the people below stay in reach; the Inbox has them all too.
    private static let voicesShown = 3

    var body: some View {
        Group {
            if model.peopleStats.isEmpty && model.reviews.isEmpty {
                MobileEmptyState(
                    systemImage: "person.2",
                    title: String(localized: "Noch niemand bekannt"),
                    message: String(localized: "Nach dem ersten Meeting erscheinen hier die Stimmen. Benenne sie einmal, dann erkennt die App sie in künftigen Meetings wieder.")
                )
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .navigationTitle(AppModel.Section.people.title)
        .toolbar {
            SettingsToolbarItem()
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(Theme.spring) { showsMap.toggle() }
                } label: {
                    Image(systemName: "circle.hexagongrid")
                }
                .tint(showsMap ? Theme.accent : nil)
                .disabled(model.peopleStats.isEmpty)
                .accessibilityLabel(Text("Stimmenkarte"))
                .accessibilityValue(showsMap ? Text("Ein") : Text("Aus"))
                .accessibilityIdentifier("people.map")
            }
        }
    }

    private var list: some View {
        List {
            if showsMap, !model.peopleStats.isEmpty {
                VoicesOverview(highlighted: nil)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.panel)
                    .listRowSeparator(.hidden)
            }
            if !model.reviews.isEmpty {
                Section {
                    let shown = allVoices ? model.reviews : Array(model.reviews.prefix(Self.voicesShown))
                    ForEach(shown) { review in
                        MobileReviewRow(review: review)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Theme.panel)
                            .listRowSeparator(.hidden)
                    }
                    if shown.count < model.reviews.count {
                        Button {
                            withAnimation(Theme.spring) { allVoices = true }
                        } label: {
                            Text(String(localized: "\(model.reviews.count - shown.count) weitere zeigen", comment: "plural: inbox, show the other voices"))
                                .font(.small)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.panel)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("people.moreVoices")
                    }
                } header: {
                    MobileSectionHeader(title: String(localized: "Zu bestätigen"), count: model.reviews.count) {
                        Button("Alle durchgehen") { model.startNaming() }
                            .font(.smallMedium)
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("people.nameAll")
                    }
                }
            }
            Section {
                ForEach(model.peopleStats) { stats in
                    let selected = wide && navigation.personInSplit == stats.person.id
                    Button {
                        navigation.open(person: stats.person.id)
                    } label: {
                        MobilePersonRow(stats: stats, mapColor: showsMap && stats.voiceSamples > 0 ? VoicesOverview.color(for: stats.person.id, among: model.people) : nil)
                    }
                    .buttonStyle(RowButtonStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(selected ? Theme.selected : Theme.panel)
                    .listRowSeparator(.hidden)
                }
            } header: {
                MobileSectionHeader(title: String(localized: "Bekannt"), count: model.peopleStats.count)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .animation(Theme.spring, value: model.reviews)
    }
}

/// A person in the list: who, how well the app knows their voice, and how much it has heard from them.
struct MobilePersonRow: View {
    let stats: PersonStats
    var mapColor: Color?

    var body: some View {
        HStack(spacing: 12) {
            Avatar(kind: stats.person.isMe ? .me(name: stats.person.name) : .person(name: stats.person.name), size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stats.person.name).font(.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                    if let mapColor {
                        Circle().fill(mapColor).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    if stats.person.isMe {
                        Chip {
                            Image(systemName: "mic").font(.system(size: 9))
                            Text("Du")
                        }
                    }
                }
                Text(details)
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                VoiceQualityBars(quality: stats.voiceQuality)
                Text(Self.qualityName(stats.voiceQuality))
                    .font(.tiny)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stats.person.name), \(details)")
        .accessibilityValue(Self.qualityName(stats.voiceQuality))
        .accessibilityIdentifier("person-\(stats.person.id)")
    }

    private var details: String {
        var parts = [String(localized: "\(stats.meetings) Meetings", comment: "plural: meetings")]
        if stats.talkTime > 0 { parts.append(TimeFormat.duration(stats.talkTime)) }
        if let last = stats.lastSeen { parts.append(TimeFormat.compactDay(last)) }
        return parts.joined(separator: " · ")
    }

    static func qualityName(_ quality: Int) -> String {
        [String(localized: "Kein Profil"), String(localized: "schwach", comment: "voice profile quality"), String(localized: "mittel", comment: "voice profile quality"), String(localized: "gut", comment: "voice profile quality")][max(0, min(quality, 3))]
    }
}

/// A voice that waits: listen to it, see where it was heard, and name it in one tap, as the Mac's row does.
struct MobileReviewRow: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    let review: VoiceReview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if isPlaying {
                    model.player.toggle()
                } else if let start = review.speaker.sampleStart, let end = review.speaker.sampleEnd {
                    Task { await model.player.play(meetingId: review.speaker.meetingId, from: start, until: end) }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.2, 2])))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .padding(.top, -6)
            .padding(.leading, -6)
            .accessibilityLabel(Text("Stimmprobe anhören"))
            .disabled(review.speaker.sampleStart == nil || !AudioArchiver.hasAudio(meetingId: review.speaker.meetingId))

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    navigation.open(meeting: review.speaker.meetingId)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(review.speaker.displayLabel).font(.uiSemibold).foregroundStyle(Theme.text)
                            Text("\(TimeFormat.duration(review.speaker.talkTime)) Sprache")
                                .font(.small)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Text("\(review.meetingTitle) · \(TimeFormat.compactDay(review.meetingDate))")
                            .font(.small)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityHint(Text("Meeting öffnen"))
                answers
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-\(review.id)")
    }

    @ViewBuilder
    private var answers: some View {
        if guesses.count > 1 {
            // Not sure between a few: one button each.
            FlowRow {
                ForEach(guesses) { person in
                    Button(person.name) { model.assign(review.speaker, to: person.id) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                otherMenu(String(localized: "Andere Person"))
            }
        } else if let name = suggestionName {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(Theme.textTertiary)
                    Avatar(kind: .person(name: name), size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.uiMedium).foregroundStyle(Theme.text).lineLimit(1)
                        if let reason = review.speaker.displayReason ?? (guesses.isEmpty ? nil : String(localized: "Stimme ähnlich", comment: "reason under a suggested name: the voice sounds like this person's")) {
                            Text(reason).font(.small).foregroundStyle(Theme.textTertiary).lineLimit(2)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Bestätigen") {
                        if let person = guesses.first, review.speaker.suggestedPersonId == nil, review.speaker.suggestedName == nil {
                            model.assign(review.speaker, to: person.id)
                        } else {
                            model.confirmSuggestion(review.speaker)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    otherMenu(String(localized: "Andere Person"))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Kein Name im Gespräch gefallen").font(.small).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    otherMenu(String(localized: "Namen vergeben"))
                    Button("Ignorieren") { model.ignoreVoice(review.speaker) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
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

    private func otherMenu(_ title: String) -> some View {
        Menu {
            if let detail = try? model.database.detail(of: review.speaker.meetingId) {
                SpeakerMenuItems(detail: detail, speaker: review.speaker)
            }
        } label: {
            Text(title)
                .font(ButtonMetrics.secondaryFont)
                .foregroundStyle(Theme.textBody)
                .padding(.horizontal, ButtonMetrics.padding - 2)
                .frame(minHeight: ButtonMetrics.height)
                .background(Capsule().fill(Theme.control))
                .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
    }
}

/// Buttons in a row that wrap onto the next line when the screen is narrow.
struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - A person

/// One person: their name, voice and meetings; merge, forget the voice or delete in the menu.
struct PersonScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    let personId: String
    @State private var name = ""
    @State private var meetings: [Meeting] = []
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var stats: PersonStats? { model.peopleStats.first { $0.person.id == personId } }

    var body: some View {
        Group {
            if let stats {
                content(stats)
            } else {
                MobileEmptyState(systemImage: "person.crop.circle.badge.xmark", title: String(localized: "Person gelöscht"), message: String(localized: "Diese Person gibt es nicht mehr."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .navigationTitle(stats?.person.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let stats {
                ToolbarItem(placement: .topBarTrailing) { menu(stats) }
            }
        }
        .onAppear {
            name = stats?.person.name ?? ""
            meetings = (try? model.database.meetings(of: personId)) ?? []
        }
        .onDisappear(perform: save)
        .confirmationDialog("\(stats?.person.name ?? "") löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let person = stats?.person {
                    navigation.forget(person: person.id)
                    model.delete(person)
                }
            }
        } message: {
            Text("Die Stimme wird vergessen. In den Meetings wird die Person wieder zu einer unbekannten Stimme.")
        }
    }

    private func content(_ stats: PersonStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Avatar(kind: stats.person.isMe ? .me(name: stats.person.name) : .person(name: stats.person.name), size: 44)
                    TextField("Name", text: $name)
                        .font(.title2.weight(.semibold))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("person.name")
                }
                Text(PersonSheet.summary(stats))
                    .font(.small)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 10)

                VoiceProfileSection(person: stats.person)
                    .padding(.top, 24)

                Text("Meetings").font(.smallSemibold).foregroundStyle(Theme.textSecondary).padding(.top, 24)
                VStack(spacing: 0) {
                    ForEach(meetings) { meeting in
                        if let row = model.row(for: meeting.id) {
                            Button {
                                save()
                                navigation.open(meeting: meeting.id)
                            } label: {
                                MobileMeetingRow(row: row, showsDay: true)
                            }
                            .buttonStyle(RowButtonStyle())
                            .padding(.horizontal, -16)
                        }
                    }
                    if meetings.isEmpty {
                        Text("Noch keinem Meeting zugeordnet.").font(.small).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func menu(_ stats: PersonStats) -> some View {
        Menu {
            if !stats.person.isMe {
                Menu("Zusammenführen …", systemImage: "arrow.triangle.merge") {
                    ForEach(model.people.filter { $0.id != personId && !$0.isMe }) { other in
                        Button(other.name) {
                            navigation.forget(person: personId)
                            model.merge(stats.person, into: other)
                        }
                    }
                }
            }
            Button("Stimme vergessen", systemImage: "waveform.slash") { model.forgetVoice(of: stats.person) }
                .disabled(stats.voiceSamples == 0)
            if !stats.person.isMe {
                Divider()
                Button("Löschen …", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("Mehr"))
        .accessibilityIdentifier("person.more")
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stats, !trimmed.isEmpty, trimmed != stats.person.name else { return }
        model.rename(stats.person, to: trimmed)
    }
}

/// On a wide iPad: the people with the one picked beside them.
struct PeopleSplit: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation

    var body: some View {
        NavigationSplitView {
            PeopleScreen()
                .environment(model)
                .environment(navigation)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            NavigationStack(path: Binding(get: { navigation.path(for: .people) }, set: { navigation.setPath($0, for: .people) })) {
                Group {
                    if let id = navigation.personInSplit, model.person(id) != nil {
                        PersonScreen(personId: id)
                            .id(id)
                    } else {
                        MobileEmptyState(systemImage: "person.2", title: String(localized: "Niemand ausgewählt"), message: String(localized: "Wähle links eine Person, um ihre Stimme und ihre Meetings zu sehen."))
                            .background(Theme.panel)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                }
            }
            .environment(\.openRoute, OpenRouteAction { [navigation] route in navigation.push(route, on: .people) })
            .environment(model)
            .environment(navigation)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
#endif
