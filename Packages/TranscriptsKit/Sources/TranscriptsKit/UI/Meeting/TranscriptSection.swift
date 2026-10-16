import SwiftUI

struct TranscriptSection: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var filter = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private enum Item: Identifiable {
        /// A line; the first of a block carries the block's lines, which "Nur diese Passage" gives to someone else.
        case line(Segment, block: [Int64]?)
        case marker(Marker)

        var id: String {
            switch self {
            case .line(let segment, _): "s\(segment.id ?? 0)"
            case .marker(let marker): "m\(marker.id ?? 0)"
            }
        }
    }

    private var items: [Item] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let segments = query.isEmpty ? detail.segments : detail.segments.filter { $0.text.lowercased().contains(query) }
        var result: [Item] = []
        var markers = query.isEmpty ? detail.markers : []
        var previous: Segment?
        var blockStart: Int?
        for segment in segments {
            while let marker = markers.first, marker.time <= segment.start {
                result.append(.marker(marker))
                markers.removeFirst()
                previous = nil
            }
            // Consecutive lines of one speaker read as one block.
            let continues = previous.map { $0.speakerKey == segment.speakerKey && segment.start - $0.end < 4 } ?? false
            if continues, query.isEmpty, let start = blockStart, case .line(let first, let block?) = result[start] {
                result[start] = .line(first, block: block + [segment.id].compactMap { $0 })
                result.append(.line(segment, block: nil))
            } else {
                blockStart = result.count
                result.append(.line(segment, block: [segment.id].compactMap { $0 }))
            }
            previous = segment
        }
        result += markers.map { .marker($0) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if searching {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField("Im Transkript suchen", text: $filter)
                            .textFieldStyle(.plain)
                            .font(.small)
                            .focused($searchFocused)
                            .onExitCommand { closeSearch() }
                        if !filter.isEmpty {
                            Text("\(detail.segments.filter { $0.text.lowercased().contains(filter.lowercased()) }.count)")
                                .font(.tiny)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        IconButton(systemName: "xmark", label: String(localized: "Suche schließen"), size: 18) { closeSearch() }
                    }
                    .padding(.leading, 8)
                    .frame(width: 230, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
                } else if !detail.segments.isEmpty {
                    IconButton(systemName: "magnifyingglass", label: String(localized: "Im Transkript suchen (⌘F)")) {
                        searching = true
                        searchFocused = true
                    }
                    .keyboardShortcut("f", modifiers: .command)
                }
            }
            .frame(height: 26)

            if detail.segments.isEmpty {
                Text(emptyText)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 14)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .line(let segment, let block):
                            TranscriptLine(detail: detail, segment: segment, block: block, highlight: filter)
                                .id(segment.id ?? 0)
                        case .marker(let marker):
                            MarkerRow(time: marker.time, text: marker.text)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        switch detail.meeting.status {
        case .recording: String(localized: "Sobald jemand spricht, erscheint hier das Live-Transkript.")
        case .processing: String(localized: "Das Transkript erscheint, sobald die Verarbeitung fertig ist.")
        case .failed: String(localized: "Kein Transkript.")
        case .ready: String(localized: "In dieser Aufnahme wurde nicht gesprochen.")
        }
    }

    private func closeSearch() {
        filter = ""
        searching = false
    }
}

/// One line of the transcript. The first line of a block says who spoke and when: a click on the name names the
/// voice, or gives just this passage to someone else; a click on the time plays from there.
struct TranscriptLine: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let segment: Segment
    /// The lines of the block this line starts, or nil for a line that continues one.
    let block: [Int64]?
    var highlight: String = ""
    @State private var hovering = false

    private var showsHeader: Bool { block != nil }
    private var isFocused: Bool { model.focusedSegmentId != nil && model.focusedSegmentId == segment.id }
    private var isPlaying: Bool {
        model.player.meetingId == detail.meeting.id && model.player.isPlaying
            && model.player.currentTime >= segment.start && model.player.currentTime < segment.end + 0.3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsHeader {
                HStack(spacing: 8) {
                    speakerMenu
                    timestamp
                    if hovering { playButton }
                }
            }
            Text(attributedText)
                .font(.reading)
                .lineSpacing(4)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topTrailing) {
                    if hovering, !showsHeader { playButton.offset(x: 28) }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, showsHeader ? 18 : 4)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : (isPlaying ? Theme.groupHeader : .clear))
                .padding(.top, showsHeader ? 12 : 0)
        )
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: isPlaying)
    }

    private var speaker: MeetingSpeaker? { detail.speaker(for: segment.speakerKey) }

    /// The name, which opens what can be said about the voice and about this passage.
    private var speakerMenu: some View {
        Menu {
            if let speaker {
                SpeakerMenuItems(detail: detail, speaker: speaker)
            }
            if let block, !block.isEmpty {
                Divider()
                Menu(String(localized: "Nur diese Passage", comment: "menu: give only these lines of the transcript to someone else")) {
                    PersonChoices(attendees: detail.meeting.attendees, excluding: speaker?.personId) { personId in
                        model.assignLines(block, in: detail.meeting.id, to: personId)
                    } newPerson: {
                        NamePrompt.ask(title: String(localized: "Wer ist das?"), message: String(localized: "Diese Zeilen werden der Person zugeordnet und ihre Stimme gemerkt.")) { name in
                            model.assignLines(block, in: detail.meeting.id, toNewPersonNamed: name)
                        }
                    }
                }
            }
            if AudioArchiver.hasAudio(meetingId: detail.meeting.id) {
                Button("Ab hier abspielen", systemImage: "play", action: play)
            }
        } label: {
            HStack(spacing: 3) {
                Text(detail.settledName(for: segment.speakerKey))
                    .font(.uiSemibold)
                    .foregroundStyle(speaker?.needsReview == true ? Theme.textSecondary : Theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovering || speaker?.needsReview == true ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(speaker?.needsReview == true ? "Klicken, um die Stimme zuzuordnen" : "Klicken, um den Sprecher zu ändern")
    }

    private var timestamp: some View {
        Button {
            play()
        } label: {
            Text(TimeFormat.clock(segment.start))
                .font(.small)
                .monospacedDigit()
                .foregroundStyle(hovering ? Theme.accent : Theme.textTertiary)
        }
        .buttonStyle(PlainPressStyle())
        .help("Ab hier abspielen")
        .disabled(!AudioArchiver.hasAudio(meetingId: detail.meeting.id))
    }

    private var playButton: some View {
        Button {
            play()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.control))
        }
        .buttonStyle(PlainPressStyle())
        .help("Ab hier abspielen")
        .opacity(AudioArchiver.hasAudio(meetingId: detail.meeting.id) ? 1 : 0)
    }

    private func play() {
        Task { await model.player.play(meetingId: detail.meeting.id, from: max(0, segment.start - 0.3)) }
    }

    private var attributedText: AttributedString {
        var text = AttributedString(segment.text)
        let query = highlight.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: query, options: .caseInsensitive) {
            text[range].backgroundColor = Theme.selectionFill
            text[range].foregroundColor = Theme.accent
            searchRange = range.upperBound..<text.endIndex
        }
        return text
    }
}
