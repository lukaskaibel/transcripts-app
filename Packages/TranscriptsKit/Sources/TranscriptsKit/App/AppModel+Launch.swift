import Foundation

extension AppModel {
    /// The model the app runs on: the user's own data, or made-up meetings with `-demo YES`.
    ///
    /// `-demo.sync <zone>` tries iCloud sync out in a zone of its own, with `-demo.data <folder>` per instance (a new
    /// folder starts empty, or with the made-up meetings with `-demo.seed YES`). `-demo.recordFrom <file>` makes
    /// recording real, with the file as the microphone (see `demoRecordingFile`).
    @MainActor
    static func makeForLaunch() -> AppModel {
        let arguments = UserDefaults.standard
        if arguments.bool(forKey: "demo") {
            // Nothing the demo does may touch real recordings. With `-demo.data <folder>` it shows a copy of
            // an app folder instead of the made-up meetings (for checking the interface on real voices).
            let copy = arguments.string(forKey: "demo.data").map { URL(fileURLWithPath: $0, isDirectory: true) }
            AppPaths.overrideRoot = copy ?? FileManager.default.temporaryDirectory.appendingPathComponent("Transcripts-Demo", isDirectory: true)
            let database: AppDatabase
            if let copy, let opened = try? AppDatabase.openShared(at: copy) {
                database = opened
                if arguments.bool(forKey: "demo.seed"), (try? opened.meetingRows().isEmpty) == true { DemoData.seed(opened) }
            } else {
                database = (try? AppDatabase.inMemory())!
                DemoData.seed(database)
            }
            // Each folder its own settings, so two instances side by side don't share them.
            let suite = copy.map { "Transcripts.demo." + SyncCoding.digest(Data($0.standardizedFileURL.path.utf8)).prefix(8) } ?? "Transcripts.demo"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            let settings = AppSettings(defaults: defaults)
            let syncZone = arguments.string(forKey: "demo.sync")
            settings.iCloudSync = syncZone != nil
            settings.onboardingDone = !arguments.bool(forKey: "demo.onboarding")
            // A real recording's transcript is never sent anywhere: the demo's key is made up.
            settings.summaryProvider = arguments.string(forKey: "demo.recordFrom") == nil ? .anthropic : nil
            settings.setModel("claude-opus-5-5", for: .anthropic)
            if let appearance = arguments.string(forKey: "demo.appearance").flatMap(Appearance.init(rawValue:)) {
                settings.appearance = appearance
            }
            let secrets = MemorySecretStore(["anthropic": "sk-ant-demo-key-0000"])
            let model = AppModel(database: database, settings: settings, secrets: secrets, isDemo: true)
            if let syncZone { model.syncZone = syncZone }
            model.loadDemoState()
            return model
        }
        do {
            return AppModel(database: try AppDatabase.openShared(), settings: AppSettings())
        } catch {
            Log.app.fault("Opening the database failed: \(error.localizedDescription)")
            let model = AppModel(database: (try? AppDatabase.inMemory())!, settings: AppSettings())
            model.showToast(String(localized: "Die Datenbank ließ sich nicht öffnen"), error.localizedDescription, isError: true)
            return model
        }
    }
}
