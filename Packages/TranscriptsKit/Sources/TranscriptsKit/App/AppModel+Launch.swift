import Foundation

extension AppModel {
    /// The model the app runs on: the user's own data, or made-up meetings with `-demo YES`.
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
            } else {
                database = (try? AppDatabase.inMemory())!
                DemoData.seed(database)
            }
            let defaults = UserDefaults(suiteName: "Transcripts.demo") ?? .standard
            defaults.removePersistentDomain(forName: "Transcripts.demo")
            let settings = AppSettings(defaults: defaults)
            settings.onboardingDone = !arguments.bool(forKey: "demo.onboarding")
            settings.summaryProvider = .anthropic
            settings.setModel("claude-opus-5-5", for: .anthropic)
            if let appearance = arguments.string(forKey: "demo.appearance").flatMap(Appearance.init(rawValue:)) {
                settings.appearance = appearance
            }
            // `-demo.github signedout` starts without GitHub; `-demo.github live` reads the real GitHub through
            // the GitHub CLI (for checking the queries on real projects), everything else is made up.
            let githubMode = arguments.string(forKey: "demo.github")
            settings.githubLogin = githubMode == "signedout" ? nil : (githubMode == "live" ? .githubCLI : .token)
            let secrets = MemorySecretStore(["anthropic": "sk-ant-demo-key-0000"])
            let github: GitHubService? = githubMode == "live" ? LiveGitHubService(tokens: GitHubTokenStore(secrets: secrets, method: .githubCLI)) : nil
            let model = AppModel(database: database, settings: settings, secrets: secrets, isDemo: true, github: github)
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
