#if os(iOS)
import SwiftUI

/// The running recording, over the whole window: the time and the level at the top, the transcript as it is spoken,
/// and the buttons to mark a moment, pause and stop at the bottom, in reach of the thumb. A wide iPad shows the live
/// summary and the markers beside the transcript, as the Mac's live window does. Closing it keeps the recording
/// running; the bar above the tab bar brings it back.
struct LiveScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wideLayout) private var wide
    @State private var showsSummary = false
    @State private var marked = 0
    @State private var renaming = false
    @State private var draftTitle = ""

    var body: some View {
        Group {
            if let session = model.recording {
                content(session)
            } else {
                MobileEmptyState(systemImage: "waveform", title: String(localized: "Keine Aufnahme"), message: String(localized: "Die Aufnahme ist beendet."))
            }
        }
        .background(Theme.panel)
        .tint(Theme.accent)
    }

    private func content(_ session: RecordingSession) -> some View {
        VStack(spacing: 0) {
            topBar(session)
            if let problem = session.microphoneProblem {
                warning(problem.message)
            }
            if wide {
                HStack(spacing: 0) {
                    LiveTranscriptView(session: session)
                    Rectangle().fill(Theme.rowSeparator).frame(width: 1)
                    LiveSidePane(session: session)
                        .frame(width: 360)
                }
            } else {
                LiveTranscriptView(session: session)
            }
            bottom(session)
        }
        .sheet(isPresented: $showsSummary) {
            LiveSidePane(session: session)
                .background(Theme.panel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.success, trigger: marked)
        .alert("Umbenennen", isPresented: $renaming) {
            TextField("Titel", text: $draftTitle)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { session.rename(draftTitle) }
        }
    }

    private func topBar(_ session: RecordingSession) -> some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Schließen"))
            .accessibilityHint(Text("Die Aufnahme läuft weiter"))
            .accessibilityIdentifier("live.close")
            Button {
                draftTitle = session.title
                renaming = true
            } label: {
                VStack(spacing: 1) {
                    Text(session.title)
                        .font(.uiSemibold)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle(session))
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityHint(Text("Umbenennen"))
            if wide {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button {
                    showsSummary = true
                } label: {
                    Image(systemName: "sparkle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(model.settings.liveSummary && model.summaryProviderReady ? Theme.accent : Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(Text("Live-Zusammenfassung"))
                .accessibilityIdentifier("live.summary")
            }
        }
        .padding(.horizontal, 6)
    }

    /// As in Voice Memos: the time, the sound of the last seconds, and the buttons in reach of the thumb.
    private func bottom(_ session: RecordingSession) -> some View {
        VStack(spacing: 10) {
            RecordingTime(session: session, label: session.state == .paused ? Text("Pausiert", comment: "the recording is paused") : Text("Aufnahme läuft"))
                .font(.system(size: 46, weight: .light))
                .monospacedDigit()
                .foregroundStyle(session.state == .paused ? Theme.textSecondary : Theme.text)
            LevelWaveform(level: { session.waveformLevel(microphoneOnly: true) }, bars: 60, height: 54, running: session.state != .paused)
                .frame(maxWidth: .infinity)
                .clipped()
            controls(session)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.groupHeader.opacity(0.6).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(text).font(.small).foregroundStyle(Theme.textBody).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Einstellungen") { model.openPrivacySettings("Privacy_Microphone") }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.warning.opacity(0.1))
    }

    private func controls(_ session: RecordingSession) -> some View {
        HStack(spacing: 40) {
            roundButton(systemImage: "bookmark", label: Text("Markieren", comment: "button: mark this moment of the recording")) {
                if session.addMarker("") != nil { marked += 1 }
            }
            .accessibilityIdentifier("live.mark")
            Button {
                Task { await model.stopRecording() }
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.recordingFill)
                    .frame(width: 30, height: 30)
                    .frame(width: 78, height: 78)
                    .background(Circle().strokeBorder(Theme.textTertiary.opacity(0.4), lineWidth: 4))
                    .contentShape(Circle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Aufnahme beenden"))
            .accessibilityIdentifier("live.stop")
            roundButton(systemImage: session.state == .paused ? "play.fill" : "pause.fill", label: session.state == .paused ? Text("Fortsetzen") : Text("Pause")) {
                model.togglePause()
            }
            .accessibilityIdentifier("live.pause")
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func roundButton(systemImage: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityLabel(label)
    }

    private func subtitle(_ session: RecordingSession) -> String {
        if session.state == .paused { return String(localized: "Pausiert", comment: "the recording is paused") }
        return session.source ?? String(localized: "Nimmt den Raum auf", comment: "the phone records everyone in the room")
    }
}
#endif
