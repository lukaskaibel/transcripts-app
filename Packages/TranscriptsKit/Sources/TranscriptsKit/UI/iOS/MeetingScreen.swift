#if os(iOS)
import SwiftUI

/// One meeting: the same sections as on the Mac, in the same order. On a wide iPad the facts and the voices stand
/// in a column beside it, as in the Mac's inspector; on the iPhone they sit between the summary and the transcript.
struct MeetingScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide
    @Environment(\.dismiss) private var dismiss
    let meetingId: String
    @State private var deleting = false
    @State private var renaming = false
    @State private var draftTitle = ""
    /// The title in the bar only once the big one has scrolled away, as in Apple's own apps.
    @State private var scrolledPastTitle = false
    @State private var width: CGFloat = 0

    /// The facts and the voices beside the meeting where there is room for both, as on the Mac.
    private var inspectorBeside: Bool { wide && width >= 760 }

    /// The meeting's detail, once the model reads this meeting.
    private var detail: MeetingDetail? {
        model.detail.flatMap { $0.meeting.id == meetingId ? $0 : nil }
    }

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if model.row(for: meetingId) == nil {
                MobileEmptyState(systemImage: "trash", title: String(localized: "Meeting gelöscht"), message: String(localized: "Dieses Meeting gibt es nicht mehr."))
            } else {
                MobileEmptyState(title: "", message: "", showsProgress: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.panel)
        .navigationTitle(scrolledPastTitle || detail == nil ? (detail?.meeting.title ?? model.row(for: meetingId)?.meeting.title ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { select() }
        .onChange(of: model.selectedMeetingId) { _, id in
            // Another screen took the model's selection, and gives it back when this one shows again.
            if id == nil, model.row(for: meetingId) != nil { select() }
        }
        .confirmationDialog("„\(detail?.meeting.title ?? "")“ löschen?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                navigation.forget(meeting: meetingId)
                model.deleteMeeting(meetingId)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Transkript, Zusammenfassung und Aufnahme werden gelöscht.")
        }
        .alert("Umbenennen", isPresented: $renaming) {
            TextField("Titel", text: $draftTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { model.rename(meetingId: meetingId, to: draftTitle) }
        }
    }

    private func select() {
        if model.selectedMeetingId != meetingId { model.selectedMeetingId = meetingId }
    }

    @ViewBuilder
    private func content(_ detail: MeetingDetail) -> some View {
        if inspectorBeside {
            HStack(spacing: 0) {
                article(detail)
                Rectangle().fill(Theme.rowSeparator).frame(width: 1).ignoresSafeArea(edges: .bottom)
                Inspector(detail: detail)
                    .frame(width: 300)
                    .background(Theme.panel)
            }
        } else {
            article(detail)
        }
    }

    private func article(_ detail: MeetingDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock(detail)
                    StatusBanner(detail: detail)
                    VoicesBanner(detail: detail)
                    SummarySection(detail: detail)
                    if !inspectorBeside, !detail.speakers.isEmpty || !detail.markers.isEmpty || !detail.meeting.attendees.isEmpty {
                        InspectorContent(detail: detail, showsTimeFacts: false)
                            .padding(16)
                            .cardStyle(radius: 14)
                            .padding(.bottom, 32)
                    }
                    TranscriptSection(detail: detail)
                }
                .padding(.horizontal, wide ? 36 : 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 56
            } action: { _, scrolled in
                withAnimation(Theme.quick) { scrolledPastTitle = scrolled }
            }
            .onChange(of: model.focusedSegmentId, initial: true) { _, id in
                guard let id else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.player.meetingId == detail.meeting.id {
                MobilePlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.overlay, value: model.player.meetingId)
        .onChange(of: detail.summary?.createdAt, initial: true) { _, written in
            if let written { model.markSummaryRead(detail.meeting.id, written: written) }
        }
    }

    private func titleBlock(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.meeting.title)
                .font(.pageTitle)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(metaLine(detail))
                .font(.ui)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 24)
    }

    private func metaLine(_ detail: MeetingDetail) -> String {
        var parts = [TimeFormat.meetingLine(start: detail.meeting.startedAt, duration: detail.meeting.duration)]
        if let source = detail.meeting.source { parts.append(source) }
        if detail.meeting.origin == .importedFile { parts.append(String(localized: "Importiert", comment: "the meeting comes from an imported audio file")) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if AudioArchiver.hasAudio(meetingId: meetingId), detail?.meeting.status == .ready || detail?.meeting.status == .failed {
                Button {
                    if model.player.meetingId == meetingId {
                        model.player.toggle()
                    } else {
                        Task { await model.player.play(meetingId: meetingId, from: 0) }
                    }
                } label: {
                    Image(systemName: model.player.meetingId == meetingId && model.player.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(model.player.meetingId == meetingId && model.player.isPlaying ? Text("Pause") : Text("Abspielen"))
                .accessibilityIdentifier("meeting.play")
            }
            Menu {
                Button("Umbenennen …", systemImage: "pencil") {
                    draftTitle = detail?.meeting.title ?? ""
                    renaming = true
                }
                if let detail, detail.meeting.status == .ready, detail.speakers.contains(where: { $0.needsReview }) {
                    Button("Wer ist das?", systemImage: "person.wave.2") { model.startNaming(meetingId) }
                }
                Divider()
                MeetingMenuItems(meetingId: meetingId) { deleting = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel(Text("Mehr"))
            .accessibilityIdentifier("meeting.more")
        }
    }
}

/// Playing a meeting back: where it is, play and pause, 15 seconds back and forth. Under the meeting while it plays.
struct MobilePlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(spacing: 2) {
            Slider(value: Binding(get: { player.currentTime }, set: { value in Task { await player.seek(to: value) } }), in: 0...max(player.duration, 1))
                .controlSize(.small)
                .accessibilityLabel(Text("Position"))
                .accessibilityValue(TimeFormat.clock(player.currentTime))
            HStack(spacing: 0) {
                Text("\(TimeFormat.clock(player.currentTime)) / \(TimeFormat.clock(player.duration))")
                    .font(.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                playerButton("gobackward.15", label: Text("15 Sekunden zurück")) { player.skip(-15) }
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.text)
                        .frame(width: 52, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Abspielen"))
                playerButton("goforward.15", label: Text("15 Sekunden vor")) { player.skip(15) }
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(Text("Wiedergabe schließen"))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private func playerButton(_ systemName: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityLabel(label)
    }
}
#endif
