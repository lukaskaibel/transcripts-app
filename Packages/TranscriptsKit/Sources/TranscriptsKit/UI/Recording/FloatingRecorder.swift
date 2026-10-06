import AppKit
import SwiftUI

/// The small recorder that floats above every window while a meeting is recorded.
@MainActor
final class FloatingRecorderController {
    private weak var model: AppModel?
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = RecorderPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 104),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: FloatingRecorderView().environment(model))
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 104)
            panel.contentView = hosting
            panel.setFrameAutosaveName("FloatingRecorder")
            if !panel.setFrameUsingName("FloatingRecorder"), let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 104 - 14))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// A panel that can become key, so its buttons react to the first click.
private final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct FloatingRecorderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.recording {
            content(session)
        } else {
            Color.clear
        }
    }

    private func content(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if session.state == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0x9A9FA8))
                        .frame(width: 8)
                } else {
                    RecordingDot()
                }
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 13, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: 0xE8E9EB))
                Text(session.title)
                    .font(.small)
                    .foregroundStyle(Color(hex: 0x9A9FA8))
                    .lineLimit(1)
                Spacer(minLength: 6)
                LevelBars(level: max(session.systemLevel, session.microphoneLevel), color: Color(hex: 0x9A9FA8), height: 13)
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: 0xE8E9EB))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(hex: 0x2A2D33)))
                }
                .buttonStyle(PlainPressStyle())
                .help(session.state == .paused ? "Fortsetzen" : "Pausieren")
                .accessibilityLabel(session.state == .paused ? "Fortsetzen" : "Pausieren")
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Aufnahme beenden")
                .accessibilityLabel("Aufnahme beenden")
            }
            .frame(height: 30)

            Rectangle().fill(Color(hex: 0x2A2D33)).frame(height: 1).padding(.vertical, 9)

            lastLine(session)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 420, height: 104, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x17181B)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: 0x2C2F36), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(count: 2) { model.request(.live) }
        .help("Doppelklicken öffnet das Live-Fenster")
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func lastLine(_ session: RecordingSession) -> some View {
        if session.systemAudioSeemsBlocked {
            Label("Vom Call kommt nichts an. Erlaube die Systemaudio-Aufnahme unter Datenschutz & Sicherheit.", systemImage: "exclamationmark.triangle")
                .font(.small)
                .foregroundStyle(Color(hex: 0xE5A84B))
                .lineLimit(2)
        } else if let line = session.partials.values.sorted(by: { $0.start > $1.start }).first ?? session.lines.last {
            HStack(alignment: .top, spacing: 9) {
                Avatar(kind: avatar(for: line.speakerKey, in: session), size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName(for: line.speakerKey))
                        .font(.smallSemibold)
                        .foregroundStyle(Color(hex: 0xE8E9EB))
                    Text(line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: line.isPartial ? 0x9A9FA8 : 0xC9CCD1))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } else {
            Text(model.engineState == .ready ? "Warte auf Sprache …" : "Spracherkennung wird geladen …")
                .font(.small)
                .foregroundStyle(Color(hex: 0x7C818A))
        }
    }

    private func avatar(for key: String, in session: RecordingSession) -> Avatar.Kind {
        guard let voice = session.voices[key] else { return key == MeetingSpeaker.meKey ? .me(name: model.myName) : .unknown(label: "?") }
        if key == MeetingSpeaker.meKey { return .me(name: model.myName) }
        if let name = voice.name { return .person(name: name) }
        return .unknown(label: voice.label)
    }
}
