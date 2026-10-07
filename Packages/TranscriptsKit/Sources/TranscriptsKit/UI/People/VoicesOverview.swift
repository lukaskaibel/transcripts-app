import SwiftUI

/// Everyone's voices on one map: each dot is a line someone said, and lines that sound alike lie close
/// together. It shows at a glance whom the app could mix up (clusters that touch), whose voice falls into
/// two groups, which lines fit nobody (rings between the clusters), and where a voice without a name falls.
///
/// The 256 dimensions of a voice are laid onto the two along which the known voices differ most, so the map
/// keeps the picture, not every distance.
struct VoicesOverview: View {
    @Environment(AppModel.self) private var model
    /// A person whose voice stands out while the others fade (hovered in the list below).
    var highlighted: String?

    @State private var layout: VoiceMapLayout?
    @State private var hovered: VoiceMapLayout.Dot?
    @State private var hoveredUnknown: VoiceMapLayout.Unknown?
    @State private var hoverLocation: CGPoint = .zero
    @State private var hoveredText: String?
    /// A name on the map under the pointer: that person's voice stands out like one hovered in the list.
    @State private var hoveredLabel: String?

    static let height: CGFloat = 270
    private static let inset: CGFloat = 26

    /// Changes whenever a voice or an unnamed voice does.
    private var signature: String {
        let voices = model.voiceLibrary.profiles.map { "\($0.key):\($0.value.samples.count):\($0.value.groups.count)" }.sorted()
        return (voices + model.reviews.map(\.id)).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Stimmenkarte").font(.uiSemibold)
                Text("Jeder Punkt ist eine Zeile; was ähnlich klingt, liegt nah beieinander.")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                legend
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    if let layout, !layout.dots.isEmpty || !layout.unknowns.isEmpty {
                        let placed = placedLabels(layout.labels, in: size)
                        Canvas { context, _ in draw(layout, labels: placed, in: &context, size: size) }
                        ForEach(placed, id: \.label.id) { item in
                            clusterLabel(item.label, at: item.position)
                        }
                        if let hovered {
                            tooltip(for: hovered)
                                .position(tooltipPosition(in: size))
                                .allowsHitTesting(false)
                        } else if let hoveredUnknown {
                            tooltip(for: hoveredUnknown)
                                .position(tooltipPosition(in: size))
                                .allowsHitTesting(false)
                        }
                    } else if layout != nil {
                        Text("Sobald jemand eine Stimme hat, zeigt die Karte, wie die Stimmen zueinander liegen.")
                            .font(.small)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverLocation = location
                        let unknown = nearestUnknown(to: location, in: size)
                        hoveredUnknown = unknown
                        let dot = unknown == nil ? nearest(to: location, in: size) : nil
                        if dot?.id != hovered?.id {
                            hovered = dot
                            hoveredText = dot?.segmentId.flatMap(text(of:))
                        }
                    case .ended:
                        hovered = nil
                        hoveredUnknown = nil
                    }
                }
                .onTapGesture { location in
                    if let unknown = nearestUnknown(to: location, in: size) {
                        model.startNaming(unknown.meetingId)
                    } else if let dot = nearest(to: location, in: size) {
                        play(dot)
                    }
                }
            }
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.rowSeparator, lineWidth: 1))
            .padding([.horizontal, .bottom], 10)
        }
        .cardStyle()
        .task(id: signature) {
            let library = model.voiceLibrary
            let people = model.people
            let reviews = model.reviews
            let computed = await Task.detached(priority: .userInitiated) {
                VoiceMapLayout(library: library, people: people, reviews: reviews)
            }.value
            guard !Task.isCancelled else { return }
            layout = computed
        }
    }

    // MARK: Drawing

    private func point(_ x: Float, _ y: Float, in size: CGSize) -> CGPoint {
        CGPoint(x: Self.inset + CGFloat(x + 1) / 2 * (size.width - 2 * Self.inset),
                y: Self.inset + CGFloat(y + 1) / 2 * (size.height - 2 * Self.inset))
    }

    private func color(for personId: String) -> Color {
        Self.color(for: personId, among: model.people)
    }

    /// Four hues that stay apart on a scatter for every pair, also for colour-blind eyes, in light and dark
    /// (blue, magenta, green, yellow; checked with the data-viz palette validator against the map's surface).
    /// More people than that can't all have a colour of their own; the rest are grey and carry their name.
    static let palette: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5),
        Color(light: 0xE87BA4, dark: 0xD55181),
        Color(light: 0x008300, dark: 0x008300),
        Color(light: 0xEDA100, dark: 0xC98500),
    ]

    /// The user is always blue; the others take the next hues in the order the app got to know them, so a
    /// person keeps their colour as others come and go.
    static func color(for personId: String, among people: [Person]) -> Color {
        if people.first(where: \.isMe)?.id == personId { return palette[0] }
        let others = people.filter { !$0.isMe }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard let index = others.firstIndex(where: { $0.id == personId }), index + 1 < palette.count else { return Theme.textTertiary }
        return palette[index + 1]
    }

    /// The person who stands out: hovered on the map, else in the list below.
    private var focused: String? { hoveredLabel ?? highlighted }

    private func draw(_ layout: VoiceMapLayout, labels: [PlacedLabel], in context: inout GraphicsContext, size: CGSize) {
        // A name that had to move away from its voice keeps a thin line to it.
        for placed in labels {
            let anchor = point(placed.label.x, placed.label.y, in: size)
            let frame = placed.frame
            guard hypot(frame.midX - anchor.x, frame.midY - anchor.y) > 30 else { continue }
            let start = CGPoint(x: min(max(anchor.x, frame.minX + 10), frame.maxX - 10), y: anchor.y > frame.midY ? frame.maxY : frame.minY)
            var line = Path()
            line.move(to: start)
            line.addLine(to: anchor)
            let faded = focused != nil && focused != placed.label.personId
            context.stroke(line, with: .color(Theme.textTertiary.opacity(faded ? 0.15 : 0.55)), lineWidth: 1)
            let end = CGRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: end), with: .color(Theme.textTertiary.opacity(faded ? 0.15 : 0.7)))
        }
        for dot in layout.dots {
            let center = point(dot.x, dot.y, in: size)
            let faded = focused != nil && focused != dot.personId
            let radius = dot.radius * (hovered?.id == dot.id ? 1.6 : 1)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let shading = color(for: dot.personId).opacity(faded ? 0.12 : (dot.isOutlier ? 0.75 : 0.72))
            if dot.isOutlier {
                context.stroke(Path(ellipseIn: rect), with: .color(shading), lineWidth: 1.2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(shading))
            }
        }
        // Voices without a name: dashed rings, over everything else.
        for unknown in layout.unknowns {
            let center = point(unknown.x, unknown.y, in: size)
            let radius: CGFloat = hoveredUnknown?.id == unknown.id ? 8.5 : 6.5
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(Theme.textSecondary.opacity(focused == nil ? 0.9 : 0.35)),
                           style: StrokeStyle(lineWidth: 1.4, dash: [2.5, 2]))
        }
    }

    /// Where the names go: at their voices, pushed apart where they would cover each other, and kept
    /// inside the map.
    private struct PlacedLabel {
        var label: VoiceMapLayout.Label
        var position: CGPoint
        var frame: CGRect
    }

    private func placedLabels(_ labels: [VoiceMapLayout.Label], in size: CGSize) -> [PlacedLabel] {
        var placed: [PlacedLabel] = []
        for label in labels.sorted(by: { $0.y < $1.y }) {
            let width = CGFloat(label.title.count) * 6.4 + 28
            let height: CGFloat = 22
            let anchor = point(label.x, label.y, in: size)
            var center = CGPoint(x: min(max(anchor.x, width / 2 + 6), size.width - width / 2 - 6), y: max(anchor.y - 18, height / 2 + 4))
            var frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            var attempts = 0
            while let blocking = placed.first(where: { $0.frame.intersects(frame) }), attempts < 12 {
                center.y = blocking.frame.maxY + height / 2 + 2
                if center.y + height / 2 > size.height - 4 { center.y = blocking.frame.minY - height / 2 - 2 }
                frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
                attempts += 1
            }
            placed.append(PlacedLabel(label: label, position: center, frame: frame))
        }
        return placed
    }

    private func clusterLabel(_ label: VoiceMapLayout.Label, at position: CGPoint) -> some View {
        let faded = focused != nil && focused != label.personId
        return Button {
            model.openPersonId = label.personId
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color(for: label.personId)).frame(width: 7, height: 7)
                Text(label.title).font(.tiny.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Theme.card.opacity(0.92)))
            .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.shadow.opacity(0.4), radius: 3, y: 1)
        }
        .buttonStyle(PlainPressStyle())
        .opacity(faded ? 0.35 : 1)
        .fixedSize()
        .onHover { inside in
            if inside { hoveredLabel = label.personId } else if hoveredLabel == label.personId { hoveredLabel = nil }
        }
        .position(position)
        .help("\(label.title) öffnen")
    }

    private func tooltip(for dot: VoiceMapLayout.Dot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(for: dot.personId)).frame(width: 7, height: 7)
                Text(model.person(dot.personId)?.name ?? "").font(.smallSemibold)
                if dot.isOutlier { Text("Ausreißer").font(.tiny).foregroundStyle(Theme.warning) }
            }
            if let hoveredText {
                Text(Strings.quote(hoveredText)).font(.small).foregroundStyle(Theme.textBody).lineLimit(3)
            }
            Text([meetingTitle(dot.meetingId), String(localized: "Klicken zum Anhören")].compactMap { $0 }.joined(separator: " · "))
                .font(.tiny)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
    }

    private func tooltip(for unknown: VoiceMapLayout.Unknown) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().strokeBorder(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5])).frame(width: 9, height: 9)
                Text("\(Strings.label(unknown.label)) · ohne Namen").font(.smallSemibold)
            }
            Text("\(unknown.meetingTitle)").font(.small).foregroundStyle(Theme.textBody).lineLimit(2)
            Text("Klicken: Wer ist das?").font(.tiny).foregroundStyle(Theme.textTertiary)
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
    }

    private func tooltipPosition(in size: CGSize) -> CGPoint {
        // Beside the pointer, on whichever side has room.
        let width: CGFloat = 260, height: CGFloat = 86
        let x = hoverLocation.x + 20 + width > size.width ? hoverLocation.x - 20 - width / 2 : hoverLocation.x + 20 + width / 2
        let y = min(max(hoverLocation.y, height / 2 + 6), size.height - height / 2 - 6)
        return CGPoint(x: x, y: y)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle().fill(Theme.textTertiary).frame(width: 6, height: 6)
                Text("Stimme")
            }
            HStack(spacing: 4) {
                Circle().stroke(Theme.textTertiary, lineWidth: 1.2).frame(width: 6, height: 6)
                Text("Ausreißer")
            }
            HStack(spacing: 4) {
                Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5])).frame(width: 8, height: 8)
                Text("ohne Namen")
            }
        }
        .font(.tiny)
        .foregroundStyle(Theme.textTertiary)
    }

    // MARK: Interaction

    private func nearest(to location: CGPoint, in size: CGSize) -> VoiceMapLayout.Dot? {
        guard let layout else { return nil }
        var best: (VoiceMapLayout.Dot, CGFloat)?
        for dot in layout.dots where focused == nil || focused == dot.personId {
            let center = point(dot.x, dot.y, in: size)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= 9, distance < (best?.1 ?? .infinity) { best = (dot, distance) }
        }
        return best?.0
    }

    private func nearestUnknown(to location: CGPoint, in size: CGSize) -> VoiceMapLayout.Unknown? {
        guard let layout else { return nil }
        return layout.unknowns
            .map { ($0, hypot(point($0.x, $0.y, in: size).x - location.x, point($0.x, $0.y, in: size).y - location.y)) }
            .filter { $0.1 <= 10 }
            .min { $0.1 < $1.1 }?.0
    }

    private func text(of segmentId: Int64) -> String? {
        let text = try? model.database.reader.read { db in try String.fetchOne(db, sql: "SELECT text FROM segment WHERE id = ?", arguments: [segmentId]) }
        return text.map { String($0.prefix(160)) }
    }

    private func meetingTitle(_ meetingId: String?) -> String? {
        guard let meetingId, let meeting = model.row(for: meetingId)?.meeting else { return nil }
        return "\(meeting.title), \(TimeFormat.compactDay(meeting.startedAt))"
    }

    private func play(_ dot: VoiceMapLayout.Dot) {
        guard let meetingId = dot.meetingId, let start = dot.start, AudioArchiver.hasAudio(meetingId: meetingId) else { return }
        Task { await model.player.play(meetingId: meetingId, from: start, until: start + min(dot.duration, 12)) }
    }
}

/// Where everything goes on the voice map, worked out once per change of the voices.
struct VoiceMapLayout: Sendable {
    struct Dot: Identifiable, Sendable {
        var id: String
        var x: Float
        var y: Float
        var personId: String
        var radius: CGFloat
        var isOutlier: Bool
        var segmentId: Int64?
        var meetingId: String?
        var start: Double?
        var duration: Double
    }

    /// A name at the middle of one of a person's voices.
    struct Label: Identifiable, Sendable {
        var id: String
        var personId: String
        var title: String
        var x: Float
        var y: Float
    }

    struct Unknown: Identifiable, Sendable {
        var id: String
        var meetingId: String
        var meetingTitle: String
        var label: String
        var x: Float
        var y: Float
    }

    var dots: [Dot] = []
    var labels: [Label] = []
    var unknowns: [Unknown] = []

    /// At most this many lines per person are drawn (the longest), so the map stays quick and readable.
    static let linesPerPerson = 300

    init(library: VoiceLibrary, people: [Person], reviews: [VoiceReview]) {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var vectors: [[Float]] = []
        var fitting: [Int] = []
        var pending: [(sample: VoiceSample, outlier: Bool, group: Int?)] = []
        var groupTitles: [String: String] = [:]
        for (personId, profile) in library.profiles where names[personId] != nil {
            var groupOf: [Int: Int] = [:]
            for group in profile.groups {
                for member in group.members { groupOf[member] = group.id }
            }
            let trusted = Set(profile.groups.filter(\.isTrusted).map(\.id))
            let shown = profile.samples.indices
                .filter { !profile.samples[$0].ignored }
                .sorted { profile.samples[$0].duration > profile.samples[$1].duration }
                .prefix(Self.linesPerPerson)
            for index in shown {
                let group = groupOf[index]
                let inVoice = group.map(trusted.contains) ?? false
                if inVoice { fitting.append(vectors.count) }
                vectors.append(profile.samples[index].embedding)
                pending.append((profile.samples[index], !inVoice, inVoice ? group : nil))
            }
            // A second voice gets its own name only with enough speech behind it; a handful of short
            // words of the same person scatter a little and are no second voice.
            let voices = profile.groups.enumerated()
                .filter { $1.isTrusted && $1.members.count >= 5 && ($0 == 0 || $1.speech >= 45) }
                .map(\.element)
            for (number, group) in voices.enumerated() {
                let name = names[personId]?.name ?? ""
                groupTitles["\(personId)#\(group.id)"] = number == 0 ? name : String(localized: "\(name) · Stimme \(number + 1)", comment: "a person's second, third, … voice on the voice map")
            }
        }
        let unknownStart = vectors.count
        let unknownReviews = reviews.filter { $0.speaker.embedding != nil }
        for review in unknownReviews { vectors.append([Float](embeddingData: review.speaker.embedding!)) }
        guard !vectors.isEmpty else { return }

        let points = VoiceMath.projection(vectors, fitting: fitting.count >= 3 ? fitting : nil)
        var sums: [String: (x: Float, y: Float, count: Float, personId: String)] = [:]
        for (index, item) in pending.enumerated() {
            let sample = item.sample
            dots.append(Dot(
                id: sample.id, x: points[index].x, y: points[index].y, personId: sample.personId,
                radius: CGFloat(1.8 + min(sample.duration, 20) / 20 * 2.4), isOutlier: item.outlier,
                segmentId: sample.segmentId, meetingId: sample.meetingId, start: sample.start, duration: sample.duration
            ))
            if let group = item.group, groupTitles["\(sample.personId)#\(group)"] != nil {
                let key = "\(sample.personId)#\(group)"
                let entry = sums[key] ?? (0, 0, 0, sample.personId)
                sums[key] = (entry.x + points[index].x, entry.y + points[index].y, entry.count + 1, sample.personId)
            }
        }
        labels = sums.compactMap { key, sum in
            guard let title = groupTitles[key], sum.count > 0 else { return nil }
            return Label(id: key, personId: sum.personId, title: title, x: sum.x / sum.count, y: sum.y / sum.count)
        }
        .sorted { $0.y < $1.y }
        unknowns = unknownReviews.enumerated().map { offset, review in
            Unknown(
                id: review.id, meetingId: review.speaker.meetingId, meetingTitle: review.meetingTitle, label: review.speaker.label,
                x: points[unknownStart + offset].x, y: points[unknownStart + offset].y
            )
        }
        // Small dots on top, so a long line never hides a short one.
        dots.sort { $0.radius > $1.radius }
    }
}
