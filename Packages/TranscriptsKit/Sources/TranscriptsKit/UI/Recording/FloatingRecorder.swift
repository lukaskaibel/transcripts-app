import AppKit
import SwiftUI

/// The small recorder that floats above every window while a meeting is recorded.
@MainActor
final class FloatingRecorderController {
    static let size = NSSize(width: 300, height: 72)
    /// A new name, so the larger recorder's old place at the top centre is forgotten once.
    private static let frameName = "FloatingRecorder.compact"

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
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: FloatingRecorderView().environment(model))
            hosting.frame = NSRect(origin: .zero, size: Self.size)
            panel.contentView = hosting
            panel.setFrameAutosaveName(Self.frameName)
            let restored = panel.setFrameUsingName(Self.frameName)
            // Out of the way of the call: the top right corner, unless it was moved somewhere that is still on screen.
            if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 16, y: frame.maxY - Self.size.height - 16))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if session.state == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(hex: 0x9A9FA8))
                        .frame(width: 8)
                } else {
                    RecordingDot()
                }
                Text(TimeFormat.clock(session.elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: 0xE8E9EB))
                Text(session.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: 0x9A9FA8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                LevelBars(level: max(session.systemLevel, session.microphoneLevel), color: Color(hex: 0x9A9FA8), height: 11)
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: 0xE8E9EB))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(hex: 0x2A2D33)))
                }
                .buttonStyle(PlainPressStyle())
                .help(session.state == .paused ? "Fortsetzen" : "Pausieren")
                .accessibilityLabel(session.state == .paused ? "Fortsetzen" : "Pausieren")
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Aufnahme beenden")
                .accessibilityLabel("Aufnahme beenden")
            }
            .frame(height: 24)

            lastLine(session)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: FloatingRecorderController.size.width, height: FloatingRecorderController.size.height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x17181B)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: 0x2C2F36), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Drag it anywhere by its background; the buttons keep their clicks.
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { model.request(.live) }
        .help("Ziehen zum Verschieben, Doppelklick öffnet das Live-Fenster")
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func lastLine(_ session: RecordingSession) -> some View {
        if let problem = session.microphoneProblem {
            warning(problem.shortMessage)
        } else if session.systemAudioSeemsBlocked {
            warning("Vom Call kommt nichts an")
        } else if let line = session.partials.values.sorted(by: { $0.start > $1.start }).first ?? session.lines.last {
            HStack(spacing: 7) {
                Avatar(kind: avatar(for: line.speakerKey, in: session), size: 16)
                Text(session.displayName(for: line.speakerKey))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE8E9EB))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(line.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(hex: line.isPartial ? 0x9A9FA8 : 0xC9CCD1))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } else {
            Text(model.engineState == .ready ? "Warte auf Sprache …" : "Spracherkennung wird geladen …")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(hex: 0x7C818A))
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(Color(hex: 0xE5A84B))
            .lineLimit(1)
    }

    private func avatar(for key: String, in session: RecordingSession) -> Avatar.Kind {
        guard let voice = session.voices[key] else { return key == MeetingSpeaker.meKey ? .me(name: model.myName) : .unknown(label: "?") }
        if key == MeetingSpeaker.meKey { return .me(name: model.myName) }
        if let name = voice.name { return .person(name: name) }
        return .unknown(label: voice.label)
    }
}
