import AppKit
import SwiftUI

/// Drives the app from a text file, for automated screenshots and UI checks.
///
/// Only active when launched with `-debugCommandFile <path>`. Every line appended to the file is one
/// command; screenshots are rendered by the app itself (so they work while the screen is locked) and
/// written to `-debugOutput <folder>`.
@MainActor
final class DebugRemote {
    static var shared: DebugRemote?

    private weak var model: AppModel?
    private let commandFile: URL
    private let output: URL
    private var handled = 0
    private var timer: Timer?
    private var panels: [NSWindow] = []

    static func startIfRequested(model: AppModel) {
        guard shared == nil, let path = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        let output = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "debugOutput") ?? NSTemporaryDirectory())
        let remote = DebugRemote(model: model, commandFile: URL(fileURLWithPath: path), output: output)
        shared = remote
        remote.start()
    }

    private init(model: AppModel, commandFile: URL, output: URL) {
        self.model = model
        self.commandFile = commandFile
        self.output = output
    }

    private func start() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard let text = try? String(contentsOf: commandFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > handled else { return }
        let new = lines[handled...]
        handled = lines.count
        for line in new { run(line) }
    }

    private func log(_ message: String) {
        let url = output.appendingPathComponent("debug.log")
        let line = message + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func run(_ line: String) {
        guard let model else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "select":
            model.select(argument.isEmpty ? nil : argument)
        case "section":
            model.section = argument == "people" ? .people : .meetings
        case "back":
            model.selectedMeetingId = nil
        case "palette":
            model.overlay = .palette
        case "closeoverlay":
            model.overlay = nil
        case "appearance":
            model.settings.appearance = Appearance(rawValue: argument) ?? .system
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : (argument == "light" ? NSAppearance(named: .aqua) : nil)
        case "icon":
            model.setAppIcon(AppIconChoice(rawValue: argument) ?? .automatic)
        case "onboarding":
            model.settings.onboardingDone = argument != "on"
        case "settings":
            model.request(.settings(AppModel.SettingsTab(rawValue: argument) ?? .general))
        case "live":
            model.startDemoRecording()
            model.request(.live)
        case "floating":
            model.startDemoRecording()
            model.floatingRecorder?.show()
        case "micproblem":
            model.recording?.showMicrophoneProblem(argument == "silent" ? .silent : (argument == "nosignal" ? .noSignal : nil))
        case "stoplive":
            model.stopDemoRecording()
        case "menubar":
            showPanel(MenuBarContent(), width: 300, title: "MenuBar")
        case "toast":
            model.showToast(argument.isEmpty ? "Zusammenfassung kopiert" : argument)
        case "focus":
            model.focusedSegmentId = Int64(argument)
        case "naming":
            model.section = .meetings
            model.startNaming(argument.isEmpty ? nil : argument)
        case "person":
            model.section = .people
            model.openPersonId = argument
        case "snap":
            snapshot(window: "main", name: argument)
        case "closesheet":
            for window in NSApp.windows where window.isSheet { window.sheetParent?.endSheet(window) }
        case "snapsheet":
            snapshot(window: "sheet", name: argument)
        case "snapwindow":
            let names = argument.split(separator: " ").map(String.init)
            if names.count == 2 { snapshot(window: names[0], name: names[1]) }
        case "snapframe":
            // The whole window with its title bar and buttons, for the README.
            let names = argument.split(separator: " ").map(String.init)
            if names.count == 2 { snapshot(window: names[0], name: names[1], frame: true) }
        case "windows":
            log(NSApp.windows.map { "\($0.title) | \($0.identifier?.rawValue ?? "-") | \($0.frame) | visible=\($0.isVisible)" }.joined(separator: "\n"))
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown command: \(line)")
        }
    }

    private func showPanel<Content: View>(_ content: Content, width: CGFloat, title: String) {
        guard let model else { return }
        let hosting = NSHostingView(rootView: content.environment(model).background(Theme.popover))
        hosting.frame.size = hosting.fittingSize
        let size = NSSize(width: width, height: max(hosting.fittingSize.height, 100))
        let panel = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        panels.append(panel)
    }

    /// Renders a window's content into a PNG, without touching the screen.
    private func snapshot(window name: String, name file: String, frame: Bool = false) {
        let window: NSWindow?
        switch name {
        case "main": window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Transcripts" && $0.styleMask.contains(.titled) && $0.frame.width > 800 }
        case "live": window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("live") == true || $0.title == "Aufnahme" }
        case "settings": window = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.identifier?.rawValue.contains("settings") == true || $0.title.contains("Allgemein") || $0.title.contains("KI") || $0.title.contains("Aufnahme") && $0.frame.width < 800 || $0.title.contains("Transkription") || $0.title.contains("Stimmen") }
        case "floating": window = NSApp.windows.first { $0 is NSPanel && $0.frame.width == FloatingRecorderController.size.width }
        case "sheet": window = NSApp.windows.first { $0.isSheet && $0.isVisible }
        default: window = NSApp.windows.first { $0.title == name }
        }
        guard let window, let content = window.contentView else {
            log("snap: no window \(name)")
            return
        }
        let view = frame ? content.superview ?? content : content

        // Give SwiftUI a moment to settle after the last change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [output] in
            view.layoutSubtreeIfNeeded()
            // Always at 2x, whichever screen the window is on.
            let size = view.bounds.size
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            if frame { Self.colourWindowButtons(of: window, in: view, on: rep) }
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: output.appendingPathComponent("\(file).png"))
            }
        }
    }
}

extension DebugRemote {
    /// The title bar's buttons in the colours of an active window: macOS draws them grey while the app isn't in front,
    /// which it often isn't while the screenshots are taken.
    static func colourWindowButtons(of window: NSWindow, in view: NSView, on rep: NSBitmapImageRep) {
        let buttons: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)),
        ]
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (type, colour) in buttons {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            var rect = button.convert(button.bounds, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            let side = min(rect.width, rect.height)
            let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            colour.setFill()
            NSBezierPath(ovalIn: circle).fill()
            colour.blended(withFraction: 0.25, of: .black)?.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension AppModel {
    /// A pretend recording for screenshots of the live window and the floating recorder.
    func startDemoRecording() {
        guard isDemo, recording == nil else { return }
        let meeting = Meeting(id: "m-live", title: "Sprint Planning 43", startedAt: Date().addingTimeInterval(-754), status: .recording, source: "Zoom",
                              attendees: [Attendee(name: "Anna Berger"), Attendee(name: "Thomas Klein"), Attendee(name: "Jonas Weber")])
        try? database.save(meeting)
        let session = RecordingSession(meeting: meeting, database: database, engine: engine, configuration: .init())
        session.loadDemo()
        recording = session
    }

    func stopDemoRecording() {
        recording = nil
        floatingRecorder?.hide()
    }
}

extension RecordingSession {
    func loadDemo() {
        loadDemoLines()
    }
}
