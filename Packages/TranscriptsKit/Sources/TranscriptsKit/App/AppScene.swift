import AppKit
import SwiftUI

/// The whole app: main window, live window, menu bar item and settings. The app target only shows this.
public struct TranscriptsScene: Scene {
    @State private var model: AppModel

    public init() {
        _model = State(initialValue: Self.makeModel())
    }

    @MainActor
    static func makeModel() -> AppModel {
        let arguments = UserDefaults.standard
        if arguments.bool(forKey: "demo") {
            // Nothing the demo does may touch real recordings.
            AppPaths.overrideRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Transcripts-Demo", isDirectory: true)
            let database = (try? AppDatabase.inMemory())!
            DemoData.seed(database)
            let defaults = UserDefaults(suiteName: "Transcripts.demo") ?? .standard
            defaults.removePersistentDomain(forName: "Transcripts.demo")
            let settings = AppSettings(defaults: defaults)
            settings.onboardingDone = !arguments.bool(forKey: "demo.onboarding")
            settings.summaryProvider = .anthropic
            settings.setModel("claude-opus-5-5", for: .anthropic)
            if let appearance = arguments.string(forKey: "demo.appearance").flatMap(Appearance.init(rawValue:)) {
                settings.appearance = appearance
            }
            let model = AppModel(database: database, settings: settings, secrets: MemorySecretStore(["anthropic": "sk-ant-demo-key-0000"]), isDemo: true)
            model.loadDemoState()
            return model
        }
        do {
            return AppModel(database: try AppDatabase.openShared(), settings: AppSettings())
        } catch {
            Log.app.fault("Opening the database failed: \(error.localizedDescription)")
            let model = AppModel(database: (try? AppDatabase.inMemory())!, settings: AppSettings())
            model.showToast("Die Datenbank ließ sich nicht öffnen", error.localizedDescription, isError: true)
            return model
        }
    }

    public var body: some Scene {
        Window("Transcripts", id: "main") {
            RootView()
                .environment(model)
                .background(WindowReader { window in
                    MainWindowObserver.shared.attach(window, model: model)
                })
                .task { model.launch() }
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Window("Aufnahme", id: "live") {
            LiveWindowView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        } label: {
            MenuBarLabel()
                .environment(model)
                .background(WindowRequestHandler().environment(model))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }
}

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Opens windows the model asks for. Lives in the menu bar label, which exists as long as the app runs.
struct WindowRequestHandler: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.windowRequestCount) {
                guard let request = model.windowRequest else { return }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                switch request {
                case .main: openWindow(id: "main")
                case .live: openWindow(id: "live")
                case .settings: openSettings()
                }
            }
    }
}

/// Hides the Dock icon when the main window closes (if wanted), and shows it again when it opens.
@MainActor
final class MainWindowObserver {
    static let shared = MainWindowObserver()
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    func attach(_ window: NSWindow?, model: AppModel) {
        guard let window, window !== self.window else { return }
        self.window = window
        window.setFrameAutosaveName("MainWindow")
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model, model.settings.hideDockIcon, !model.isDemo else { return }
                // Keep the Dock icon while another window (the live window) is still open.
                let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.isRecording ? "Aufnahme beenden" : "Aufnahme starten") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Pause / Fortsetzen") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isRecording)
            Button("Markierung setzen") { model.recording?.addMarker("") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.isRecording)
            Divider()
            Button("Audiodatei importieren …") { importFiles() }
                .keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu("Gehe zu") {
            Button("Suchen …") { model.overlay = model.overlay == .palette ? nil : .palette }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Meetings") { model.select(nil) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Personen") { model.section = .people }
                .keyboardShortcut("2", modifiers: .command)
            Button("Live-Fenster") { model.request(.live) }
                .keyboardShortcut("l", modifiers: .command)
            Button("Alle Meetings öffnen") { model.openMainWindow() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.importableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Wähle Aufnahmen, die transkribiert werden sollen."
        guard panel.runModal() == .OK else { return }
        model.importAudio(panel.urls)
    }
}
