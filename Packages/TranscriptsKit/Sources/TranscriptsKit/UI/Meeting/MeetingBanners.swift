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
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.suggestion))
            .padding(.bottom, 22)
    }
}

/// "2 Stimmen ohne Namen", as Mail shows a suggestion above a message: a quiet grey bar with the way into naming
/// them, one after another.
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
                HStack(spacing: 12) {
                    icon
                    text(open).fixedSize()
                    Spacer()
                    button
                }
                HStack(alignment: .top, spacing: 12) {
                    icon.padding(.top, 2)
                    VStack(alignment: .leading, spacing: 10) {
                        text(open)
                        button
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Platform.isMobile ? 16 : 12, style: .continuous).fill(Theme.suggestion))
            .padding(.bottom, 22)
        }
    }

    private var icon: some View {
        Image(systemName: "person.wave.2")
            .font(.system(size: Platform.isMobile ? 20 : 17))
            .foregroundStyle(Theme.accent)
    }

    private func text(_ open: [MeetingSpeaker]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "\(open.count) Stimmen ohne Namen", comment: "plural: voices in a meeting nobody has named yet")).font(.uiSemibold)
            Text(hint(open)).font(.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private var button: some View {
        Button(String(localized: "Stimmen benennen …", comment: "button: name the voices of a meeting one after another")) { model.startNaming(detail.meeting.id) }
            #if os(macOS)
            .buttonStyle(.bordered)
            #else
            .buttonStyle(PrimaryButtonStyle())
            #endif
            .accessibilityIdentifier("voices.name")
    }

    /// Whom the app thinks it heard, in a sentence; or what naming does.
    private func hint(_ open: [MeetingSpeaker]) -> String {
        let guessed = open.lazy.compactMap { speaker in detail.guesses(for: speaker).first?.name ?? speaker.suggestedName }.first
        guard let guessed else { return String(localized: "Anhören und benennen, dann erkennt die App sie wieder.") }
        return open.count == 1
            ? String(localized: "Vermutlich \(guessed).", comment: "under one voice without a name: whom the app thinks it is")
            : String(localized: "Eine davon ist vermutlich \(guessed).", comment: "under several voices without a name: whom the app thinks one of them is")
    }
}

/// Playing a meeting back: a floating bar over the page, as the system's own players float over their content.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.panel)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.text))
            }
            .buttonStyle(PlainPressStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Leertaste)" : "Abspielen (Leertaste)")
            IconButton(systemName: "gobackward.15", label: String(localized: "15 Sekunden zurück")) { player.skip(-15) }
            IconButton(systemName: "goforward.15", label: String(localized: "15 Sekunden vor")) { player.skip(15) }
            Text(TimeFormat.clock(player.currentTime)).font(.small).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(get: { player.currentTime }, set: { value in Task { await player.seek(to: value) } }), in: 0...max(player.duration, 1))
                .controlSize(.small)
                .frame(minWidth: 160)
            Text(TimeFormat.clock(player.duration)).font(.small).monospacedDigit().foregroundStyle(Theme.textTertiary)
            IconButton(systemName: "xmark", label: String(localized: "Wiedergabe schließen"), size: 24) { player.stop() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 46)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 24)
    }
}
