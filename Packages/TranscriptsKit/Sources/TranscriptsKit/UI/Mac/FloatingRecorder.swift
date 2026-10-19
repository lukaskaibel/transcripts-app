#if os(macOS)
import AppKit
import SwiftUI

/// The small recorder that floats above every window while a meeting is recorded: a glass capsule with the time,
/// the sound coming in, pause and stop. It names nobody (who is talking right now is only guessed during the
/// meeting and settled afterwards); with the pointer over it, it shows the last words it heard.
@MainActor
final class FloatingRecorderController {
    static let compact = NSSize(width: 252, height: 64)
    static let expanded = NSSize(width: 372, height: 104)
    static let identifier = NSUserInterfaceItemIdentifier("FloatingRecorder")
    /// A new name, so the dark recorder's old place is forgotten once.
    private static let frameName = "FloatingRecorder.glass"

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
                contentRect: NSRect(origin: .zero, size: Self.compact),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = Self.identifier
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            // The capsule draws its own shadow; the window's would follow the transparent margin.
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: FloatingRecorderView { [weak self] expanded in
                // After SwiftUI's update, not in the middle of it.
                DispatchQueue.main.async { self?.setExpanded(expanded) }
            }.environment(model))
            // The panel's size is this controller's alone. Sized by its content as well, SwiftUI grew the panel back
            // whenever it shrank before the second line was gone, the two resized it in turn, and AppKit ended the
            // app for too many layout passes (2026-10-19, hovering over the recorder while it showed a warning).
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            hosting.frame = NSRect(origin: .zero, size: Self.compact)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            // The demo's recorder has a place of its own: trying the app out doesn't move the real one.
            let frameName = model.isDemo ? Self.frameName + ".demo" : Self.frameName
            let saved = Self.savedFrame(frameName)
            panel.setFrameAutosaveName(frameName)
            if let saved {
                panel.setFrame(NSRect(x: saved.maxX - Self.compact.width, y: saved.maxY - Self.compact.height, width: Self.compact.width, height: Self.compact.height), display: false)
            }
            // Out of the way of the call: the top right corner, unless it was moved somewhere that is still on screen.
            if saved == nil || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.compact.width - 8, y: visible.maxY - Self.compact.height - 8))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Where the recorder was last, as AppKit saved it. AppKit puts back only the top left corner of a panel that
    /// can't be resized, but the recorder hangs from its top right one: saved while it was wide, it came back further
    /// left every time.
    private static func savedFrame(_ name: String) -> NSRect? {
        guard let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") else { return nil }
        let numbers = saved.split(separator: " ").prefix(4).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// Grows down and to the left from the top right corner, so the buttons stay under the pointer.
    func setExpanded(_ expanded: Bool) {
        guard let panel else { return }
        let size = expanded ? Self.expanded : Self.compact
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.x = frame.maxX - size.width
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }
}

/// A panel that can become key, so its buttons react to the first click.
private final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct FloatingRecorderView: View {
    @Environment(AppModel.self) private var model
    /// Asks the panel to make room for a second line, or to shrink back.
    var expand: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if let session = model.recording {
                content(session)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(8)
    }

    private func content(_ session: RecordingSession) -> some View {
        let problem = problem(session)
        let expanded = hovering || problem != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if session.state == .paused {
                    Circle().fill(Theme.textTertiary).frame(width: 8, height: 8)
                } else {
                    RecordingDot()
                }
                RecordingTime(session: session)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(session.state == .paused ? Theme.textSecondary : Theme.text)
                if expanded {
                    Text(session.title)
                        .font(.small)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if session.state == .paused {
                    Text(String(localized: "Pausiert", comment: "the recording is paused"))
                        .font(.small)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LevelWaveform(level: { session.waveformLevel() }, bars: 9, height: 20, barWidth: 3, spacing: 2, running: session.state != .paused)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.text.opacity(0.08)))
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
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .buttonStyle(PlainPressStyle())
                .help("Aufnahme beenden")
                .accessibilityLabel("Aufnahme beenden")
            }
            if expanded {
                secondLine(session, problem: problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            // Glass shows what lies behind the panel, which a capture of the window alone doesn't have: the demo's
            // pictures get the colour glass has over a plain desktop.
            if model.isDemo {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.popover.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 0.5))
            }
        }
        .glassEffect(model.isDemo ? .identity : .regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Drag it anywhere by its background; the buttons keep their clicks.
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { model.request(.live) }
        .onHover { inside in
            withAnimation(Theme.quick) { hovering = inside }
        }
        .onChange(of: expanded, initial: true) { _, wanted in expand(wanted) }
        .help("Ziehen zum Verschieben, Doppelklick öffnet das Live-Fenster")
    }

    /// What is wrong with the sound, if anything: the recorder shows it until it is fixed.
    private func problem(_ session: RecordingSession) -> (text: String, pane: String)? {
        if let problem = session.microphoneProblem { return (problem.shortMessage, "Privacy_Microphone") }
        if session.systemAudioSeemsBlocked { return (String(localized: "Vom Call kommt nichts an"), "Privacy_ScreenCapture") }
        return nil
    }

    /// The last words heard, without a name; or the problem with a way to fix it.
    @ViewBuilder
    private func secondLine(_ session: RecordingSession, problem: (text: String, pane: String)?) -> some View {
        if let problem {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(problem.text).font(.small).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Button(String(localized: "Beheben …", comment: "floating recorder: opens the privacy settings that block the sound")) {
                    model.openPrivacySettings(problem.pane)
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
            .padding(.trailing, 6)
        } else if let line = session.partials.values.sorted(by: { $0.start > $1.start }).first ?? session.lines.last {
            Text(line.text)
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.trailing, 10)
        } else {
            Text(model.engineState == .ready ? "Warte auf Sprache …" : "Spracherkennung wird geladen …")
                .font(.small)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
#endif
