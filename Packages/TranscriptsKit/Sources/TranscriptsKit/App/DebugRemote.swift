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
        DebugFrames.isActive = true
        Dropdown.trace = { [weak self] message in self?.log("dropdown: \(message)") }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var pending: [String] = []
    private var waiting = false

    private func poll() {
        guard let text = try? String(contentsOf: commandFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > handled else { return }
        pending += lines[handled...]
        handled = lines.count
        drain()
    }

    /// Runs the queued commands in order; `wait <seconds>` pauses the queue, so a whole UI run can be written at once.
    private func drain() {
        guard !waiting else { return }
        while !pending.isEmpty {
            let line = pending.removeFirst()
            if line.hasPrefix("wait "), let seconds = Double(line.dropFirst(5)) {
                waiting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.waiting = false
                    self?.drain()
                }
                return
            }
            run(line)
        }
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
        case "upcoming":
            // upcoming <event id>: the popover of a meeting in "Anstehend", in a window of its own.
            if let meeting = model.upcoming.first(where: { $0.eventId == argument }) {
                showPanel(UpcomingPopover(meeting: meeting) {}, width: 280, title: "Upcoming")
            }
        case "notmine":
            // notmine <event id>: "Nicht mein Meeting" on a reminder.
            model.handle(.notMine(eventId: argument, title: argument))
        case "hidecalendar":
            if let meeting = model.upcoming.first(where: { $0.eventId == argument }), let item = HiddenCalendarItem.calendar(of: meeting) { model.hide(item) }
        case "calendarreport":
            // calendarreport [hours]
            log(model.calendar.report(hours: Double(argument) ?? 36, filter: model.meetingFilter).joined(separator: "\n"))
        case "unhideall":
            for item in model.settings.hiddenMeetings { model.unhide(item) }
        case "calendar":
            log("upcoming=\(model.upcoming.map { "\($0.eventId)[\($0.calendarTitle ?? "-")]" }) hidden=\(model.settings.hiddenMeetings.map(\.id)) onlyMine=\(model.settings.onlyMyMeetings) toasts=\(model.toasts.map { "\($0.title) | \($0.message) | \($0.action?.title ?? "-")" })")
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
        case "mark":
            log("mark: \(argument)")
        case "activate":
            NSApp.activate()
        case "key":
            // key <text>: types the characters into the key window, as the keyboard would.
            for character in argument { sendKey(characters: String(character), code: 0) }
        case "keycode":
            // keycode <code> [cmd] [shift]: Return 36, Escape 53, Space 49, arrows 125 (down) 126 (up), Tab 48.
            let bits = argument.split(separator: " ").map(String.init)
            if let code = bits.first.flatMap({ UInt16($0) }) {
                var modifiers: NSEvent.ModifierFlags = []
                if bits.contains("cmd") { modifiers.insert(.command) }
                if bits.contains("shift") { modifiers.insert(.shift) }
                let characters = [36: "\r", 51: "\u{7F}", 53: "\u{1B}", 49: " ", 48: "\t", 125: String(UnicodeScalar(NSDownArrowFunctionKey)!), 126: String(UnicodeScalar(NSUpArrowFunctionKey)!)][Int(code)] ?? ""
                if code == 125 || code == 126 { modifiers.insert([.numericPad, .function]) }
                sendKey(characters: characters, code: code, modifiers: modifiers)
            }
        case "clickid":
            // clickid <id>: clicks the middle of a view marked with `debugFrame`.
            guard let (window, frame) = DebugFrames.locate(argument) else {
                log("clickid: \(argument) not on screen; visible: \(DebugFrames.visibleIds.joined(separator: " "))")
                return
            }
            click(in: window, at: NSPoint(x: frame.midX, y: frame.midY))
        case "ids":
            log("ids: \(DebugFrames.visibleIds.joined(separator: " "))")
        case "responder":
            let key = NSApp.keyWindow
            let first = key?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            log("responder: key=\(key.map { String(describing: type(of: $0)) } ?? "nil")#\(key?.windowNumber ?? 0) first=\(first.prefix(60)) panels=\(Dropdown.isOpen) selected=\(model.selectedMeetingId ?? "-")")
        case "composer":
            // composer <meeting> [task id] | composer close
            let bits = argument.split(separator: " ").map(String.init)
            if argument == "close" { Dropdown.close() } else if let meeting = bits.first { model.requestComposer(for: meeting, item: bits.count > 1 ? Int64(bits[1]) : nil) }
        case "dump":
            dump(model)
        case "ghclose":
            if let demo = model.github as? DemoGitHubService { Task { await demo.close(argument) } }
        case "ghrefresh":
            Task { await model.refreshLinkedIssues(of: argument, force: true) }
        case "ghtarget":
            // ghtarget <owner/repo>: points the open composer at that repository (in its first project, if any).
            if let composer = model.composer,
               let target = model.githubCatalog?.targets.first(where: { $0.repo == argument && $0.projectId != nil }) ?? model.githubCatalog?.targets.first(where: { $0.repo == argument }) {
                model.setTarget(target, in: composer)
            } else {
                log("ghtarget: no composer or no target \(argument); targets: \(model.githubCatalog?.targets.map(\.title).prefix(12).joined(separator: ", ") ?? "-")")
            }
        case "ghmeta":
            // ghmeta <owner/repo>: what the app knows about a repository.
            if let target = model.githubCatalog?.targets.first(where: { $0.repo == argument }) {
                let meta = model.githubRepoMeta[target.repoId]
                log("ghmeta \(argument): labels=\(meta?.labels.map(\.name) ?? []) people=\(meta?.assignableUsers.map(\.login) ?? []) open=\(model.githubOpenIssues[target.repoId]?.prefix(5).map { "#\($0.number) \($0.title) \($0.statuses.values.first ?? "-")" } ?? [])")
            }
        case "ghsignout":
            model.signOutGitHub()
        case "ghconnect":
            Task { await model.connectGitHubCLI() }
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown command: \(line)")
        }
    }

    /// What the composer and the meeting's tasks look like right now, for checking a UI run.
    private func dump(_ model: AppModel) {
        var lines: [String] = []
        if let composer = model.composer {
            lines.append("composer meeting=\(composer.meetingId) only=\(composer.only.map(String.init) ?? "-") target=\(composer.target?.title ?? "-") reason=\(composer.suggestion?.short ?? "-") active=\(composer.activeIndex) context=\(composer.includeContext) loading=\(composer.loadingMeta) drafting=\(composer.drafting) creating=\(composer.creating) button=\"\(composer.createTitle)\" canCreate=\(composer.canCreate) error=\(composer.error ?? "-")")
            let statuses = model.statusOptions(for: composer.target)
            let labels = model.labels(for: composer.target)
            for draft in composer.drafts {
                let status = statuses.first { $0.id == draft.statusId }?.name ?? "-"
                let names = draft.labelIds.compactMap { id in labels.first { $0.id == id }?.name }
                let mode = draft.linkedRef.map { "link #\($0.number)" } ?? "create"
                lines.append("  [\(draft.include ? "x" : " ")] \(draft.itemId) \"\(draft.title)\" status=\(status) labels=\(names) suggested=\(draft.labelsAreSuggested) assignees=\(draft.assignees.map(\.login)) mode=\(mode) note=\(draft.note ?? "-")")
            }
        } else {
            lines.append("composer: none")
        }
        if let detail = model.detail {
            for item in detail.actionItems {
                lines.append("  task \(item.id ?? 0) done=\(item.done) \"\(item.text)\" issue=\(item.issue.map { "\($0.reference) \($0.status ?? "-") \($0.state)" } ?? "-")")
            }
        }
        lines.append("github=\(model.githubConnection) routes=\(model.githubRoutes.count) people=\(model.people.compactMap { p in p.github.map { "\(p.firstName)=\($0.login)" } })")
        lines.append("toasts=\(model.toasts.map(\.title)) panels=\(Dropdown.isOpen) key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
        log(lines.joined(separator: "\n"))
    }

    private func click(in window: NSWindow, at location: NSPoint) {
        let types: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]
        let events = types.compactMap { type in
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard events.count == 2 else { return }
        // AppKit controls track the mouse in a loop that reads the queue until the button comes up,
        // so the release waits in the queue before the press is sent.
        NSApp.postEvent(events[1], atStart: false)
        NSApp.sendEvent(events[0])
    }

    private func sendKey(characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        // To the key window, as a real key press would go: a dropdown if one is open.
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        let front = numbers.lazy.compactMap { NSApp.window(withWindowNumber: $0.intValue) }.first { $0 is DropdownPanel && $0.isVisible }
        guard let window = NSApp.keyWindow ?? front ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) {
                NSApp.sendEvent(event)
            }
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
        case "settings": window = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.identifier?.rawValue.contains("settings") == true || $0.title.contains("Allgemein") || $0.title.contains("KI") || $0.title.contains("Aufnahme") && $0.frame.width < 800 || $0.title.contains("Transkription") || $0.title.contains("Stimmen") || $0.title == "GitHub" }
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
            // With dropdowns open, they are drawn in on top.
            let data = (window.childWindows ?? []).contains(where: \.isVisible) ? Self.composite(window, content: view, base: rep) : rep.representation(using: .png, properties: [:])
            if let data {
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

    /// The window's content with the dropdowns open above it drawn in, each with a soft shadow, at twice the size.
    static func composite(_ window: NSWindow, content view: NSView, base rep: NSBitmapImageRep) -> Data? {
        func children(of window: NSWindow) -> [NSWindow] {
            (window.childWindows ?? []).filter(\.isVisible).flatMap { [$0] + children(of: $0) }
        }
        let base = window.convertToScreen(view.convert(view.bounds, to: nil))
        let layers = children(of: window).compactMap { child -> (NSRect, NSBitmapImageRep)? in
            guard let content = child.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            return (child.convertToScreen(content.convert(content.bounds, to: nil)), rep)
        }
        let bounds = layers.reduce(base) { $0.union($1.0.insetBy(dx: -24, dy: -24)) }
        let scale: CGFloat = 2
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        rep.draw(in: NSRect(x: base.minX - bounds.minX, y: base.minY - bounds.minY, width: base.width, height: base.height))
        for (frame, layer) in layers {
            let target = NSRect(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY, width: frame.width, height: frame.height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: target.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: target, xRadius: 10, yRadius: 10).addClip()
            layer.draw(in: target)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
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
