import SwiftUI

/// Recording, processing or failed: what the meeting is waiting for.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    var body: some View {
        switch detail.meeting.status {
        case .recording:
            banner {
                RecordingDot()
                Text("Aufnahme läuft").font(.uiMedium)
                Text("Das Transkript unten ist vorläufig.").foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Live-Fenster") { model.request(.live) }.buttonStyle(SecondaryButtonStyle())
            }
        case .processing:
            banner {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.meeting.processingStep ?? String(localized: "Wird verarbeitet")).font(.uiMedium)
                    ThinBar(fraction: detail.meeting.progress)
                        .frame(maxWidth: 260)
                }
                Spacer()
                Text(detail.meeting.progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current))).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
        case .failed:
            banner {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verarbeitung fehlgeschlagen").font(.uiMedium)
                    if let message = detail.meeting.errorMessage {
                        Text(message).font(.small).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Erneut versuchen") { model.reprocess(detail.meeting.id) }.buttonStyle(SecondaryButtonStyle())
            }
        case .ready:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle()
            .padding(.bottom, 24)
    }
}

/// "2 Stimmen ohne Namen": the way into naming them, one after another.
struct VoicesBanner: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetail

    private var open: [MeetingSpeaker] {
        detail.speakers.filter { $0.needsReview && $0.talkTime >= 4 }
    }

    var body: some View {
        let open = open
        if detail.meeting.status == .ready, !open.isEmpty {
            // Side by side where there is room; on a phone the button goes under the text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    icon
                    text(open).fixedSize()
                    Spacer()
                    button
                }
                HStack(alignment: .top, spacing: 10) {
                    icon.padding(.top, 2)
                    VStack(alignment: .leading, spacing: 10) {
                        text(open)
                        button
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .cardStyle(radius: Platform.isMobile ? 14 : 10)
            .padding(.bottom, 24)
        }
    }

    private var icon: some View {
        Image(systemName: "person.wave.2").foregroundStyle(Theme.warning)
    }

    private func text(_ open: [MeetingSpeaker]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "\(open.count) Stimmen ohne Namen", comment: "plural: voices in a meeting nobody has named yet")).font(.uiMedium)
            Text(hint(open)).font(.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var button: some View {
        Button("Wer ist das?") { model.startNaming(detail.meeting.id) }
            .buttonStyle(PrimaryButtonStyle())
    }

    private func hint(_ open: [MeetingSpeaker]) -> String {
        let guessed = open.filter { !detail.guesses(for: $0).isEmpty || $0.suggestedName != nil }
        guard !guessed.isEmpty else { return String(localized: "Anhören und benennen, dann erkennt die App sie wieder.") }
        return guessed.map { detail.displayName(for: $0.key) }.joined(separator: " · ")
    }
}

struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.control))
            }
            .buttonStyle(PlainPressStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            IconButton(systemName: "gobackward.15", label: String(localized: "15 Sekunden zurück")) { player.skip(-15) }
            IconButton(systemName: "goforward.15", label: String(localized: "15 Sekunden vor")) { player.skip(15) }
            Text(TimeFormat.clock(player.currentTime)).font(.small).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { player.currentTime }, set: { value in Task { await player.seek(to: value) } }), in: 0...max(player.duration, 1))
                .controlSize(.small)
            Text(TimeFormat.clock(player.duration)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
            IconButton(systemName: "xmark", label: String(localized: "Wiedergabe schließen"), size: 22) { player.stop() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }
}
