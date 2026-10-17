import SwiftUI

// MARK: - People

/// A round badge with initials, as Contacts draws one: grey, white letters. Unknown voices are a dashed ring.
struct Avatar: View {
    enum Kind: Equatable {
        case person(name: String)
        case me(name: String)
        case unknown(label: String)
    }

    var kind: Kind
    var size: CGFloat = 20
    var ring: Color? = nil

    var body: some View {
        ZStack {
            switch kind {
            case .person(let name), .me(let name):
                Circle().fill(Self.monogram)
                Text(Self.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            case .unknown:
                Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2.4, 2.2]))
                Text(verbatim: "?")
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let ring { Circle().stroke(ring, lineWidth: 2).padding(-1) }
        }
        .accessibilityHidden(true)
    }

    /// Contacts' grey, a little darker so the white letters read.
    private static let monogram = LinearGradient(
        colors: [Color(light: 0x9A9EA8, dark: 0x6E7079), Color(light: 0x7A7E88, dark: 0x55575F)],
        startPoint: .top, endPoint: .bottom
    )

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// "Sprecher 4" → "4", anything else → "?".
    static func number(_ label: String) -> String {
        label.split(separator: " ").last.flatMap { Int($0) }.map(String.init) ?? "?"
    }
}

extension MeetingDetail {
    /// The name of whoever the voice is, once that is settled; until then its label ("Sprecher 4"), never a guess
    /// with a question mark.
    func settledName(for key: String) -> String {
        guard let speaker = speaker(for: key) else { return key == MeetingSpeaker.meKey ? Strings.me : key }
        if let personId = speaker.personId, let person = people[personId] { return person.name }
        if speaker.isMe { return Strings.me }
        return speaker.displayLabel
    }

    func avatarKind(for key: String) -> Avatar.Kind {
        guard let speaker = speaker(for: key) else { return key == MeetingSpeaker.meKey ? .me(name: Strings.me) : .unknown(label: key) }
        if let personId = speaker.personId, let person = people[personId] {
            return person.isMe ? .me(name: person.name) : .person(name: person.name)
        }
        if speaker.isMe { return .me(name: Strings.me) }
        return .unknown(label: speaker.label)
    }
}

extension MeetingRow {
    func avatarKinds(people: [String: Person]) -> [Avatar.Kind] {
        speakers.map { speaker in
            if let personId = speaker.personId, let person = people[personId] {
                return person.isMe ? .me(name: person.name) : .person(name: person.name)
            }
            return speaker.isMe ? .me(name: Strings.me) : .unknown(label: speaker.label)
        }
    }
}

struct AvatarStack: View {
    var kinds: [Avatar.Kind]
    var size: CGFloat = 20
    var limit = 4
    var ring = Theme.panel

    var body: some View {
        HStack(spacing: 4) {
            // Overlapping only as far as the initials stay readable.
            HStack(spacing: -1) {
                ForEach(Array(kinds.prefix(limit).enumerated()), id: \.offset) { _, kind in
                    Avatar(kind: kind, size: size, ring: ring)
                }
            }
            if kinds.count > limit {
                Text("+\(kinds.count - limit)")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Small pieces

struct Chip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.tiny)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(Capsule().stroke(Theme.chipBorder, lineWidth: 1))
    }
}

struct DotChip: View {
    var text: String
    var color: Color

    var body: some View {
        Chip {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

struct Keycap: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.tiny)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.keycapBorder, lineWidth: 1))
    }
}

/// Square icon button used in headers.
struct IconButton: View {
    var systemName: String
    var label: Text
    var size: CGFloat = 26
    var tint: Color = Theme.textSecondary
    var action: () -> Void

    init(systemName: String, label: LocalizedStringKey, size: CGFloat = 26, tint: Color = Theme.textSecondary, action: @escaping () -> Void) {
        self.init(systemName: systemName, label: Text(label), size: size, tint: tint, action: action)
    }

    /// For a label that is already localized. Disfavoured like SwiftUI's own, so a literal stays a localized key.
    @_disfavoredOverload
    init<S: StringProtocol>(systemName: String, label: S, size: CGFloat = 26, tint: Color = Theme.textSecondary, action: @escaping () -> Void) {
        self.init(systemName: systemName, label: Text(label), size: size, tint: tint, action: action)
    }

    private init(systemName: String, label: Text, size: CGFloat, tint: Color, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Platform.isMobile ? 15 : 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Platform.isMobile ? max(size, 30) : size, height: Platform.isMobile ? max(size, 30) : size)
                .hoverFill(radius: 6)
                #if os(iOS)
                // A finger needs more room than the icon takes; the layout stays as it is.
                .padding(7)
                .contentShape(Rectangle())
                .padding(-7)
                #endif
        }
        .buttonStyle(PlainPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The red recording dot, with a soft ring while it pulses.
struct RecordingDot: View {
    var size: CGFloat = 8
    var pulsing = true
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.recording)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Theme.recording.opacity(0.35), lineWidth: 4)
                    .scaleEffect(on ? 1.6 : 1)
                    .opacity(pulsing ? (on ? 0 : 0.8) : 0)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
            .accessibilityLabel("Aufnahme läuft")
    }
}

/// The running recording's time. A view of its own because the time changes four times a second: only this text
/// draws again, not the screen around it. With a label, VoiceOver reads it as one element, the label and the time.
struct RecordingTime: View {
    let session: RecordingSession
    var label: Text?

    var body: some View {
        let time = TimeFormat.clock(session.elapsed)
        if let label {
            Text(time)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(time)
        } else {
            Text(time)
        }
    }
}

/// A channel's level as `LevelBars`, in a view of its own: the level changes about twelve times a second.
struct ChannelLevelBars: View {
    let session: RecordingSession
    var channel: Channel = .microphone
    var color: Color = Theme.textSecondary
    var height: CGFloat = 14

    var body: some View {
        LevelBars(level: channel == .microphone ? session.microphoneLevel : session.systemLevel, color: color, height: height)
    }
}

/// Five bars that show a level between 0 and 1.
struct LevelBars: View {
    var level: Float
    var color: Color = Theme.textSecondary
    var height: CGFloat = 14

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<6, id: \.self) { index in
                let threshold = Float(index) / 6
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level > threshold + 0.02 ? color : Theme.barOff)
                    .frame(width: 3, height: height * CGFloat(index + 2) / 7)
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// Three bars that show how well the app knows a voice.
struct VoiceQualityBars: View {
    var quality: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(quality >= step ? Theme.textBody : Theme.barOff)
                    .frame(width: 3, height: CGFloat(2 + step * 3))
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
        .accessibilityLabel([String(localized: "Kein Stimmprofil"), String(localized: "Schwaches Stimmprofil"), String(localized: "Mittleres Stimmprofil"), String(localized: "Gutes Stimmprofil")][max(0, min(quality, 3))])
    }
}

/// The circle in front of a meeting: what state its transcript and summary are in.
struct MeetingGlyph: View {
    enum State {
        case summarized, transcribed, processing(Double), recording, failed, upcoming
    }

    var state: State
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            switch state {
            case .summarized:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Theme.onColor)
            case .transcribed:
                Circle().strokeBorder(Theme.textSecondary, lineWidth: 1.5)
            case .processing(let fraction):
                Circle().strokeBorder(Theme.warning, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: max(0.08, fraction))
                    .rotation(.degrees(-90))
                    .fill(Theme.warning)
                    .padding(size * 0.22)
            case .recording:
                RecordingDot(size: size * 0.55, pulsing: false)
            case .failed:
                Circle().fill(Theme.warning)
                Text("!")
                    .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.onColor)
            case .upcoming:
                Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.3]))
            }
        }
        .frame(width: size, height: size)
    }
}

extension MeetingRow {
    var glyph: MeetingGlyph.State {
        switch meeting.status {
        case .recording: .recording
        case .processing: .processing(meeting.progress)
        case .failed: .failed
        case .ready: hasSummary ? .summarized : .transcribed
        }
    }
}

/// A heading over a group of rows, as in Mail's lists: plain text, no bar.
struct SectionHeader: View {
    var title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.uiSemibold)
            if let count { Text("\(count)").foregroundStyle(Theme.textTertiary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState<Accessory: View>: View {
    var systemImage: String?
    var title: Text
    var message: Text
    var accessory: Accessory

    init(systemImage: String? = nil, title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory) {
        self.init(systemImage: systemImage, title: Text(title), message: Text(message), accessory: accessory())
    }

    /// For texts that are already localized. Disfavoured like SwiftUI's own, so literals stay localized keys.
    @_disfavoredOverload
    init<Title: StringProtocol, Message: StringProtocol>(systemImage: String? = nil, title: Title, message: Message, @ViewBuilder accessory: () -> Accessory) {
        self.init(systemImage: systemImage, title: Text(title), message: Text(message), accessory: accessory())
    }

    private init(systemImage: String?, title: Text, message: Text, accessory: Accessory) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.accessory = accessory
    }

    /// As the system shows an empty list: a large symbol, the title, a line of explanation, and what to do.
    var body: some View {
        ContentUnavailableView {
            if let systemImage {
                Label { title } icon: { Image(systemName: systemImage) }
            } else {
                title
            }
        } description: {
            message.frame(maxWidth: 400)
        } actions: {
            accessory
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Accessory == EmptyView {
    init(systemImage: String? = nil, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }

    @_disfavoredOverload
    init<Title: StringProtocol, Message: StringProtocol>(systemImage: String? = nil, title: Title, message: Message) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// A thin horizontal bar, for talk share and progress.
struct ThinBar: View {
    var fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rowSeparator)
                Capsule().fill(color).frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// A text that becomes a field on double click, like a title in Finder.
struct EditableText: View {
    var text: String
    var font: Font
    var onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onAppear { focused = true }
            } else {
                Text(text)
                    .font(font)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) {
                        draft = text
                        editing = true
                    }
                    .help("Doppelklicken zum Umbenennen")
            }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if draft != text { onCommit(draft) }
    }
}

#if os(macOS)
/// Reads the window a view lives in.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
#endif

/// The sound of the last seconds as bars, newest on the right, as Voice Memos draws a recording. It reads the level
/// itself on every tick and keeps its own short history, so the view around it doesn't redraw for every change; the
/// bars are drawn in one canvas, not as a view each.
struct LevelWaveform: View {
    var level: () -> Float
    var bars = 60
    var color: Color = Theme.recording
    var height: CGFloat = 40
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    /// Off while paused: the bars stand still.
    var running = true
    @State private var history = History()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !running)) { timeline in
            let samples = history.samples(at: timeline.date, count: bars, running: running, level: level)
            Canvas { context, size in
                for (index, value) in samples.enumerated() {
                    let barHeight = max(barWidth, height * CGFloat(value))
                    let bar = CGRect(x: CGFloat(index) * (barWidth + spacing), y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                    let opacity = 0.3 + 0.7 * Double(index) / Double(max(bars - 1, 1))
                    context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(color.opacity(opacity)))
                }
            }
            .frame(width: CGFloat(bars) * (barWidth + spacing) - spacing, height: height)
        }
        .accessibilityHidden(true)
    }

    /// The last levels, newest last. A class, so that taking a sample doesn't make the view draw a second time.
    private final class History {
        private var levels: [Float] = []
        private var sampledAt: Date?

        /// One new sample per tick of the timeline; the view drawing again within a tick takes none.
        func samples(at date: Date, count: Int, running: Bool, level: () -> Float) -> [Float] {
            if running, date != sampledAt {
                sampledAt = date
                levels.append(min(max(level(), 0), 1))
                if levels.count > count { levels.removeFirst(levels.count - count) }
            }
            return Array(repeating: 0, count: max(0, count - levels.count)) + levels
        }
    }
}
