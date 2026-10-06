import AppKit
import SwiftUI

// MARK: - People

/// A round badge with initials. The user is grey, unknown voices are a dashed ring.
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
            case .person(let name):
                Circle().fill(Theme.color(for: name))
                Text(Self.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x111214))
            case .me(let name):
                Circle().fill(Theme.meColor)
                Text(Self.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x111214))
            case .unknown(let label):
                Circle().strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.2, 2]))
                Text(Self.number(label))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if let ring { Circle().stroke(ring, lineWidth: 2).padding(-1) }
        }
        .accessibilityHidden(true)
    }

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
    var label: String
    var size: CGFloat = 26
    var tint: Color = Theme.textSecondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .hoverFill(radius: 6)
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
        .accessibilityLabel(["Kein Stimmprofil", "Schwaches Stimmprofil", "Mittleres Stimmprofil", "Gutes Stimmprofil"][max(0, min(quality, 3))])
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

struct SectionHeader: View {
    var title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.uiSemibold)
            if let count { Text("\(count)").foregroundStyle(Theme.textTertiary) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.groupHeader))
    }
}

struct EmptyState<Accessory: View>: View {
    var systemImage: String?
    var title: String
    var message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 8)
            }
            Text(title).font(.uiSemibold)
            Text(message)
                .font(.ui)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            accessory.padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

extension EmptyState where Accessory == EmptyView {
    init(systemImage: String? = nil, title: String, message: String) {
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
