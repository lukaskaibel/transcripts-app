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
            header(session)
            if let problem = session.microphoneProblem {
                warning(problem.message)
            }
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
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
            controls(session)
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

    private func header(_ session: RecordingSession) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if session.state == .paused {
                    Image(systemName: "pause.fill").font(.title3.weight(.bold)).foregroundStyle(Theme.textSecondary)
                } else {
                    RecordingDot(size: 12)
                }
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(session.state == .paused ? Theme.textSecondary : Theme.text)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.footnote).foregroundStyle(Theme.textTertiary)
                LevelBars(level: session.microphoneLevel, color: Theme.textSecondary, height: 16)
                Text(session.state == .paused ? String(localized: "Pausiert", comment: "the recording is paused") : String(localized: "Nimmt den Raum auf", comment: "the phone records everyone in the room"))
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.state == .paused ? Text("Pausiert", comment: "the recording is paused") : Text("Aufnahme läuft"))
        .accessibilityValue(TimeFormat.clock(session.elapsed))
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
        HStack(spacing: 0) {
            controlButton(systemImage: "bookmark", title: String(localized: "Markieren", comment: "button: mark this moment of the recording")) {
                if session.addMarker("") != nil { marked += 1 }
            }
            .accessibilityIdentifier("live.mark")
            .frame(maxWidth: .infinity)
            Button {
                model.togglePause()
            } label: {
                Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.text)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.control))
                    .contentShape(Circle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(session.state == .paused ? Text("Fortsetzen") : Text("Pause"))
            .accessibilityIdentifier("live.pause")
            .frame(maxWidth: .infinity)
            Button {
                Task { await model.stopRecording() }
            } label: {
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white).frame(width: 20, height: 20)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .contentShape(Circle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Aufnahme beenden"))
            .accessibilityIdentifier("live.stop")
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowSeparator).frame(height: 1) }
    }

    private func controlButton(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 44, height: 32)
                Text(title).font(.tiny)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 64, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
    }

    private func subtitle(_ session: RecordingSession) -> String {
        var parts: [String] = []
        if let source = session.source { parts.append(source) }
        parts.append(String(localized: "\(session.voices.count) Stimmen", comment: "plural: voices heard so far in the recording"))
        return parts.joined(separator: " · ")
    }
}
#endif
