import SwiftUI

struct TranscriptSection: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    @State private var filter = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private enum Item: Identifiable {
        case line(Segment, showsHeader: Bool)
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
        for segment in segments {
            while let marker = markers.first, marker.time <= segment.start {
                result.append(.marker(marker))
                markers.removeFirst()
                previous = nil
            }
            // Consecutive lines of one speaker read as one block.
            let continues = previous.map { $0.speakerKey == segment.speakerKey && segment.start - $0.end < 4 } ?? false
            result.append(.line(segment, showsHeader: !continues || !query.isEmpty))
            previous = segment
        }
        result += markers.map { .marker($0) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Transkript").font(.uiSemibold)
                Text(TimeFormat.duration(detail.meeting.duration)).foregroundStyle(Theme.textTertiary)
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
                        IconButton(systemName: "xmark", label: "Suche schließen", size: 18) { closeSearch() }
                    }
                    .padding(.leading, 8)
                    .frame(width: 230, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control))
                } else if !detail.segments.isEmpty {
                    IconButton(systemName: "magnifyingglass", label: "Im Transkript suchen (⌘F)") {
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
                        case .line(let segment, let showsHeader):
                            TranscriptLine(detail: detail, segment: segment, showsHeader: showsHeader, highlight: filter)
                                .id(segment.id ?? 0)
                        case .marker(let marker):
                            MarkerRow(time: marker.time, text: marker.text)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private var emptyText: String {
        switch detail.meeting.status {
        case .recording: "Sobald jemand spricht, erscheint hier das Live-Transkript."
        case .processing: "Das Transkript erscheint, sobald die Verarbeitung fertig ist."
        case .failed: "Kein Transkript."
        case .ready: "In dieser Aufnahme wurde nicht gesprochen."
        }
    }

    private func closeSearch() {
        filter = ""
        searching = false
    }
}

struct TranscriptLine: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let segment: Segment
    let showsHeader: Bool
    var highlight: String = ""
    @State private var hovering = false

    private var isFocused: Bool { model.focusedSegmentId != nil && model.focusedSegmentId == segment.id }
    private var isPlaying: Bool {
        model.player.meetingId == detail.meeting.id && model.player.isPlaying
            && model.player.currentTime >= segment.start && model.player.currentTime < segment.end + 0.3
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if showsHeader {
                    Avatar(kind: detail.avatarKind(for: segment.speakerKey), size: 22)
                } else {
                    Color.clear.frame(width: 22, height: 1)
                }
            }
            .padding(.top, showsHeader ? 0 : 0)
            VStack(alignment: .leading, spacing: 2) {
                if showsHeader {
                    HStack(spacing: 8) {
                        // Where the guesses stand as buttons, the label says who isn't settled yet.
                        Text(showsGuesses ? (detail.speaker(for: segment.speakerKey)?.label ?? "") : detail.displayName(for: segment.speakerKey)).font(.uiSemibold)
                        timestamp
                        if let speaker = detail.speaker(for: segment.speakerKey), speaker.needsReview, isFirstLine {
                            SuggestionChip(detail: detail, speaker: speaker)
                        }
                        if segment.placement == .app {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .help("Von der App hierher verschoben, weil es so klingt. Rechts unter „Sprecher“ lässt es sich zurücknehmen.")
                        }
                        if hovering { playButton }
                    }
                }
                Text(attributedText)
                    .font(.reading)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .topTrailing) {
                        if hovering, !showsHeader { playButton.offset(x: 28) }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, showsHeader ? 14 : 4)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : (isPlaying ? Theme.groupHeader : .clear))
                .padding(.top, showsHeader ? 8 : 0)
        )
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: isPlaying)
    }

    private var showsGuesses: Bool {
        guard isFirstLine, let speaker = detail.speaker(for: segment.speakerKey), speaker.needsReview else { return false }
        return !detail.guesses(for: speaker).isEmpty || (speaker.suggestedPersonId == nil && speaker.suggestedName != nil)
    }

    private var isFirstLine: Bool {
        detail.segments.first { $0.speakerKey == segment.speakerKey }?.id == segment.id
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

/// "Jonas Weber?" (or "Hai?" "Julian?") next to a voice the app thinks it recognised, one click each.
struct SuggestionChip: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail
    let speaker: MeetingSpeaker

    var body: some View {
        HStack(spacing: 4) {
            ForEach(detail.guesses(for: speaker)) { person in
                chip(person.name, help: person.id == speaker.suggestedPersonId ? speaker.suggestionReason : "Stimme ähnlich") {
                    model.assign(speaker, to: person.id)
                }
            }
            if speaker.suggestedPersonId == nil, let name = speaker.suggestedName {
                chip(name, help: speaker.suggestionReason) { model.confirmSuggestion(speaker) }
            }
        }
    }

    private func chip(_ name: String, help: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("\(name)?")
            }
            .font(.tiny.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(Capsule().stroke(Theme.selectionBorder, lineWidth: 1))
        }
        .buttonStyle(PlainPressStyle())
        .help(help.map { "\(name) zuordnen · \($0)" } ?? "\(name) zuordnen")
    }
}
