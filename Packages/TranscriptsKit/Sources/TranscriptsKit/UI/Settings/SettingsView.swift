import AppKit
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppModel.SettingsTab = .general

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Allgemein", systemImage: "slider.horizontal.3") }
                .tag(AppModel.SettingsTab.general)
            RecordingSettings()
                .tabItem { Label("Aufnahme", systemImage: "mic") }
                .tag(AppModel.SettingsTab.recording)
            TranscriptionSettings()
                .tabItem { Label("Transkription", systemImage: "waveform") }
                .tag(AppModel.SettingsTab.transcription)
            AISettings()
                .tabItem { Label("KI", systemImage: "sparkle") }
                .tag(AppModel.SettingsTab.ai)
            VoiceSettings()
                .tabItem { Label("Stimmen", systemImage: "person.2") }
                .tag(AppModel.SettingsTab.voices)
            GitHubSettings()
                .tabItem {
                    Label {
                        Text("GitHub")
                    } icon: {
                        if let mark = GitHubMark.image(size: 17) { Image(nsImage: mark) } else { Image(systemName: "arrow.up.forward.app") }
                    }
                }
                .tag(AppModel.SettingsTab.github)
        }
        .frame(width: 600)
        .onAppear(perform: followRequest)
        .onChange(of: model.windowRequestCount) { followRequest() }
    }

    private func followRequest() {
        if case .settings(let requested) = model.windowRequest { tab = requested }
    }
}

// MARK: - General

/// One of the app icons to choose from, with a ring when it's the current one.
struct AppIconButton: View {
    var choice: AppIconChoice
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image = choice.image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 52, height: 52)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                )
                Text(choice.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel("App-Icon \(choice.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var language = AppLanguage.chosen()

    /// The choice the app started with and the language it shows since; another choice shows from the next start on.
    private static let start = (choice: AppLanguage.chosen(), shown: AppLanguage.current)

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Dein Name") {
                    TextField("", text: $name, prompt: Text("Name"))
                        .frame(width: 220)
                        .onSubmit(saveName)
                }
                Picker("Sprache", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                .onChange(of: language) { AppLanguage.choose(language) }
                Text("Die Sprachen, die die Spracherkennung zuverlässig versteht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if needsRestart {
                    HStack {
                        Text(busy ? "Nach der Aufnahme möglich." : "Gilt nach einem Neustart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten", action: relaunch)
                            .disabled(busy)
                    }
                }
                Picker("Erscheinungsbild", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("App-Icon") {
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 10) {
                            ForEach(AppIconChoice.allCases) { choice in
                                AppIconButton(choice: choice, selected: settings.appIcon == choice) { model.setAppIcon(choice) }
                            }
                        }
                        Text("„Automatisch“ passt sich an wie die Icons von macOS: hell, dunkel, getönt oder klar. Die anderen zeigt das Dock, solange die App läuft.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Beim Anmelden starten", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Ohne offenes Fenster nur in der Menüleiste", isOn: $settings.hideDockIcon)
            }

            Section("Kalender") {
                PermissionRow(title: "Kalenderzugriff", allowed: model.calendarAllowed, request: { Task { await model.requestCalendar() } }, pane: "Privacy_Calendars")
                Toggle("Beim Start eines Meetings erinnern", isOn: $settings.calendarReminders)
                    .onChange(of: settings.calendarReminders) { model.refreshCalendar() }
                Picker("Erinnerung", selection: $settings.reminderLead) {
                    Text("Zum Beginn").tag(0.0)
                    Text("1 Minute vorher").tag(60.0)
                    Text("2 Minuten vorher").tag(120.0)
                    Text("5 Minuten vorher").tag(300.0)
                }
                .disabled(!settings.calendarReminders)
                .onChange(of: settings.reminderLead) { model.refreshCalendar() }
                Toggle("Calls ohne Kalendereintrag erkennen", isOn: $settings.detectCalls)
                    .onChange(of: settings.detectCalls) { model.configureCallDetection() }
                Text("Meldet sich, wenn Zoom, Teams, Meet im Browser & Co. das Mikrofon benutzen, und wenn der Call vorbei ist, die Aufnahme aber noch läuft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Nur Meetings, bei denen du dabei bist", isOn: $settings.onlyMyMeetings)
                    .onChange(of: settings.onlyMyMeetings) { model.refreshCalendar() }
                Text("Termine mit Gästen, zu denen du weder eingeladen bist noch selbst eingeladen hast, erscheinen nicht, etwa aus dem geteilten Kalender eines Teams. Andere blendest du beim Termin mit „Nicht mein Meeting“ aus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !settings.hiddenMeetings.isEmpty {
                Section("Ausgeblendet") {
                    ForEach(settings.hiddenMeetings.reversed()) { item in
                        HiddenMeetingRow(item: item)
                    }
                }
            }

            Section("Mitteilungen") {
                PermissionRow(title: "Mitteilungen", allowed: model.notificationsAllowed, request: { Task { await model.requestNotifications() } }, pane: nil)
                if model.notificationsAllowed == true, !model.persistentAlerts {
                    HStack(alignment: .top) {
                        Text("Stell den Stil auf „Dauerhaft“, damit eine Erinnerung stehen bleibt, bis du „Aufnehmen“ klickst.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Öffnen") { model.openNotificationSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            name = model.me?.name ?? AppModel.defaultMyName
            model.refreshPermissions()
        }
        .onDisappear(perform: saveName)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var me = try? model.database.mePerson(defaultName: trimmed), me.name != trimmed else { return }
        me.name = trimmed
        try? model.database.save(me)
    }

    private var needsRestart: Bool {
        language != Self.start.choice && Self.effective(language) != Self.start.shown
    }

    /// A restart would end the recording or the processing of a meeting.
    private var busy: Bool {
        model.recording != nil || model.processingMeetingId != nil
    }

    /// The language the interface shows with `choice` after a start, like `AppLanguage.current`.
    private static func effective(_ choice: AppLanguage) -> AppLanguage {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        guard available.count > 1 else { return .german }
        guard choice == .system else { return choice }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: system).first.flatMap { AppLanguage(code: $0) } ?? .english
    }

    /// Opens the app again as a new instance, then quits this one.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// A meeting series or calendar the user hid, with the way back.
private struct HiddenMeetingRow: View {
    @Environment(AppModel.self) private var model
    let item: HiddenCalendarItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == .calendar ? "calendar" : (item.isRecurring ? "repeat" : "calendar.badge.minus"))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Einblenden") { model.unhide(item) }
        }
    }

    private var kind: String {
        switch item.kind {
        case .calendar:
            String(localized: "Ganzer Kalender", comment: "a hidden calendar: all of its meetings")
        case .event:
            [item.isRecurring ? String(localized: "Serie", comment: "a hidden recurring calendar meeting") : String(localized: "Einzelner Termin", comment: "a hidden calendar meeting that doesn't repeat"),
             item.calendarTitle].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    var title: LocalizedStringKey
    var allowed: Bool?
    var request: () -> Void
    var pane: String?

    var body: some View {
        LabeledContent(title) {
            switch allowed {
            case true?:
                Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case false?:
                Button("In den Systemeinstellungen erlauben") {
                    if let pane { model.openPrivacySettings(pane) } else { model.openNotificationSettings() }
                }
            case nil:
                Button("Erlauben", action: request)
            }
        }
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []
    @State private var storage: Int64 = 0

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                PermissionRow(title: "Mikrofonzugriff", allowed: model.microphoneAllowed, request: { Task { await model.requestMicrophone() } }, pane: "Privacy_Microphone")
                Picker("Mikrofon", selection: $settings.microphoneUID) {
                    Text(AudioSystem.defaultInputName.map { String(localized: "Systemstandard (\($0))", comment: "microphone: the system's default input, with its name") } ?? String(localized: "Systemstandard")).tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                Toggle("Ton des Calls aufnehmen", isOn: $settings.captureSystemAudio)
                Text("Nimmt alles auf, was der Mac abspielt, getrennt von deinem Mikrofon. So weiß die App sicher, was du gesagt hast und was die anderen. Läuft der Call über die Lautsprecher, landet er auch im Mikrofon; diese doppelten Zeilen lässt die App weg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Während der Aufnahme") {
                Toggle("Schwebende Leiste anzeigen", isOn: $settings.floatingRecorder)
                Toggle("Live-Fenster öffnen", isOn: $settings.openLiveWindow)
            }
            Section("Speicher") {
                Picker("Aufnahmen", selection: $settings.audioRetention) {
                    ForEach(AudioRetention.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Belegt") {
                    HStack {
                        Text(TimeFormat.fileSize(storage)).foregroundStyle(.secondary)
                        Button("Im Finder zeigen") {
                            try? FileManager.default.createDirectory(at: AppPaths.recordings, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.recordings])
                        }
                    }
                }
                Text("Transkripte und Zusammenfassungen bleiben immer erhalten; mit der Aufnahme kannst du Stellen nachhören und neu transkribieren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            devices = AudioSystem.inputDevices()
            model.refreshPermissions()
            Task.detached {
                let size = AppPaths.sizeOfRecordings()
                await MainActor.run { storage = size }
            }
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(TranscriptionModel.allCases) { option in
                    HStack(spacing: 10) {
                        Image(systemName: option == model.settings.transcriptionModel ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(option == model.settings.transcriptionModel ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option.isDownloaded {
                            Text(String(localized: "Geladen", comment: "speech model: its files are downloaded")).font(.caption).foregroundStyle(.secondary)
                            if option != model.settings.transcriptionModel {
                                Button("Löschen") { try? option.deleteFiles() }
                                    .controlSize(.small)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.changeTranscriptionModel(option) }
                }
            } header: {
                Text("Spracherkennung")
            } footer: {
                Text("Parakeet läuft auf der Neural Engine dieses Macs und versteht 25 europäische Sprachen, auch gemischt. Nichts davon geht ins Internet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("Modelle") {
                    switch model.engineState {
                    case .ready:
                        Label("Bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .preparing(let step, let fraction):
                        HStack {
                            ProgressView(value: fraction).frame(width: 120)
                            Text("\(step) · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))").font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        HStack {
                            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            Button("Erneut laden") { model.prepareEngine() }
                        }
                    case .idle:
                        Button(model.modelsDownloaded ? String(localized: "Laden", comment: "button: load the downloaded speech models") : String(localized: "Herunterladen")) { model.prepareEngine() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - AI

struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProviderKind?
    @State private var draftKey = ""
    @State private var ollamaURL = ""
    @State private var saving = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.autoSummarize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatisch zusammenfassen")
                        Text(settings.autoSummarize ? "Sobald ein Transkript fertig ist." : "Aus · im Meeting per Klick auf „Erstellen“.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Anbieter", selection: $settings.summaryProvider) {
                    Text(String(localized: "Keiner", comment: "summary provider: none")).tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases.filter { model.isConfigured($0) || settings.summaryProvider == $0 }) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
                if let kind = settings.summaryProvider {
                    Picker("Modell", selection: Binding(get: { model.model(for: kind) ?? "" }, set: { model.choose(model: $0, for: kind) })) {
                        ForEach(model.providerModels[kind] ?? []) { option in
                            Text(option.name).tag(option.id)
                        }
                        if model.providerModels[kind] == nil, let current = model.model(for: kind) {
                            Text(current).tag(current)
                        }
                    }
                }
                Picker("Sprache", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Anbieter") {
                ForEach([ProviderKind.anthropic, .openAI, .google]) { kind in
                    providerRow(kind)
                }
                ollamaRow
            }

            Section {
                Label("API-Keys liegen im macOS-Schlüsselbund. Für eine Zusammenfassung geht nur der Text des Transkripts an den Anbieter – mit Ollama verlässt nichts deinen Mac.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { ollamaURL = model.settings.ollamaURL }
    }

    @ViewBuilder
    private func providerRow(_ kind: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    status(kind)
                }
                Spacer()
                if editing != kind {
                    if model.isConfigured(kind) {
                        Button("Ändern") { startEditing(kind) }
                        Button("Entfernen", role: .destructive) { model.removeKey(for: kind) }
                    } else {
                        Button("Key hinzufügen") { startEditing(kind) }
                    }
                }
            }
            if editing == kind {
                HStack {
                    SecureField(kind.keyPlaceholder, text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { save(kind) }
                    Button("Abbrechen") { editing = nil }
                    Button(saving ? "Prüfe …" : "Prüfen und speichern") { save(kind) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                if let url = kind.keyHelpURL {
                    Link("Wo bekomme ich einen Key?", destination: url).font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func status(_ kind: ProviderKind) -> some View {
        switch model.providerStatus[kind] ?? (model.isConfigured(kind) ? .checking : .notConfigured) {
        case .notConfigured:
            Text("Nicht verbunden").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Wird geprüft …").font(.caption).foregroundStyle(.secondary)
        case .connected:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(kind == .ollama ? "Verbunden · \(Self.models(model.providerModels[kind]?.count ?? 0))" : "Verbunden · \(masked(kind))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private var ollamaRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama")
                    status(.ollama)
                }
                Spacer()
                TextField("", text: $ollamaURL, prompt: Text("http://localhost:11434"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 190)
                    .onSubmit { Task { await model.connectOllama(url: ollamaURL) } }
                Button("Verbinden") { Task { await model.connectOllama(url: ollamaURL) } }
            }
            Text("Lokale Modelle, ganz ohne Internet. Lange Meetings werden in Teilen zusammengefasst.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func models(_ count: Int) -> String {
        String(localized: "\(count) Modelle", comment: "plural: language models found in Ollama")
    }

    private func masked(_ kind: ProviderKind) -> String {
        guard let key = model.apiKey(for: kind), key.count > 8 else { return "" }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    private func startEditing(_ kind: ProviderKind) {
        draftKey = ""
        editing = kind
    }

    private func save(_ kind: ProviderKind) {
        saving = true
        Task {
            if await model.saveKey(draftKey, for: kind) { editing = nil }
            saving = false
        }
    }
}

// MARK: - Voices

struct VoiceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.learnVoices) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sicher erkannte Stimmen dazulernen")
                        Text("Eindeutig erkannte Stimmen verfeinern, was die App über eine Person weiß, damit sie sich mit der Zeit verändern darf. Sie zählen nur, wo sie zu einer bestätigten Stimme passen. Bestätigte Zuordnungen lernt die App immer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Automatisch zuordnen", selection: $settings.voiceStrictness) {
                    ForEach(VoiceStrictness.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.voiceStrictness.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("Stimmbibliothek") {
                LabeledContent("Personen", value: "\(model.peopleStats.count)")
                LabeledContent("Stimmproben", value: "\(model.peopleStats.reduce(0) { $0 + $1.voiceSamples })")
                Button("Alle Stimmen vergessen …", role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Alle Stimmen vergessen?", isPresented: $confirmReset) {
            Button("Vergessen", role: .destructive) {
                for stats in model.peopleStats { model.forgetVoice(of: stats.person) }
            }
        } message: {
            Text("Die Personen und ihre Zuordnungen bleiben, aber die App erkennt niemanden mehr an der Stimme, bis sie neu gelernt hat.")
        }
    }
}

// MARK: - GitHub

struct GitHubSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                account
            } footer: {
                Text("Transcripts legt Issues mit denselben Rechten an wie Issues for GitHub: Issues und Projekte deiner Repositories und Organisationen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Neue Issues") {
                Toggle(isOn: $settings.githubSuggestLabels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Labels vorschlagen")
                        Text("Das Modell der Zusammenfassung wählt passende Labels aus denen, die es im Repository schon gibt, schreibt eine kurze Beschreibung und lässt Aufgaben weg, die nicht ins Repository gehören.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.githubIncludeContext) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kontext aus dem Transkript")
                        Text("Zwei Sätze Beschreibung und ein Zitat mit Zeitstempel. Bei öffentlichen Repositories nie.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $settings.githubAskAfterSummary) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nach der Zusammenfassung fragen")
                        Text("Eine Mitteilung mit „Anlegen“, sobald die Aufgaben eines Meetings bereitstehen, dessen Ziel die App sich gemerkt hat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if model.githubRoutes.isEmpty {
                    Text("Noch nichts gemerkt. Sobald du Aufgaben nach GitHub schickst, merkt sich die App das Ziel für die Kalenderserie, den Titel und die Runde.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(RouteGroup.groups(model.githubRoutes)) { group in
                        RouteRow(group: group)
                    }
                }
            } header: {
                Text("Gemerkte Ziele")
            } footer: {
                if !model.githubRoutes.isEmpty {
                    Text("Lernt bei jedem Anlegen dazu. Serien kommen aus dem Kalender, Runden aus den erkannten Stimmen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.refreshGitHubCatalog() }
    }

    @ViewBuilder
    private var account: some View {
        if let user = model.githubConnection.user {
            HStack(spacing: 10) {
                GitHubAvatar(user: user, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name.map { "\($0) (\(user.login))" } ?? user.login)
                    Text(model.settings.githubLogin == .githubCLI ? "Angemeldet über die GitHub-CLI, wie Issues for GitHub" : "Angemeldet auf github.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abmelden") { model.signOutGitHub() }
            }
        } else if let code = model.githubDeviceCode {
            HStack(spacing: 10) {
                Text(code.userCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Text("Code kopiert – auf github.com einfügen").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
                Button("Abbrechen") { model.cancelGitHubDeviceFlow() }
            }
        } else {
            HStack(spacing: 10) {
                GitHubMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nicht verbunden")
                    if case .failed(let message) = model.githubConnection {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else if case .connecting = model.githubConnection {
                        Text("Verbinde …").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Aufgaben direkt als Issues anlegen").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.githubDeviceFlowAvailable {
                    Button("Im Browser anmelden") { model.startGitHubDeviceFlow() }
                }
                if model.githubCLIAvailable {
                    Button("GitHub-CLI verwenden") { Task { await model.connectGitHubCLI() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// A calendar series and its title remember the same thing; the settings show them as one.
struct RouteGroup: Identifiable {
    var routes: [GitHubRoute]
    var id: String { routes.compactMap(\.id).map(String.init).joined(separator: "-") }
    /// The one that names the kind: the series when there is one.
    var main: GitHubRoute { routes.first { $0.kind == .series } ?? routes[0] }

    static func groups(_ routes: [GitHubRoute]) -> [RouteGroup] {
        var result: [RouteGroup] = []
        for route in routes {
            if route.kind != .people,
               let index = result.firstIndex(where: { $0.main.kind != .people && $0.main.label == route.label && $0.main.targetKey == route.targetKey }) {
                result[index].routes.append(route)
            } else {
                result.append(RouteGroup(routes: [route]))
            }
        }
        return result
    }
}

/// One remembered target, with the button to forget it.
private struct RouteRow: View {
    @Environment(AppModel.self) private var model
    let group: RouteGroup
    private var route: GitHubRoute { group.main }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.kind == .people ? "person.2" : (route.kind == .series ? "calendar" : "text.quote"))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.label).lineLimit(1)
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TargetLabel(target: route.target)
                .foregroundStyle(.primary)
            Text("\(group.routes.map(\.count).max() ?? route.count)×").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
            Button {
                for route in group.routes { model.forgetRoute(route) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Vergessen")
        }
    }

    private var kind: String {
        switch route.kind {
        case .series: String(localized: "Kalenderserie", comment: "a remembered GitHub target: for the meetings of a recurring calendar event")
        case .title: String(localized: "Gleicher Titel", comment: "a remembered GitHub target: for meetings with this title")
        case .people: String(localized: "Gleiche Runde", comment: "a remembered GitHub target: for meetings with these people")
        }
    }
}
