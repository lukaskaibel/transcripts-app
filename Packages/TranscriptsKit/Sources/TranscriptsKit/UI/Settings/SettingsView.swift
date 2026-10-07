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

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Dein Name") {
                    TextField("", text: $name, prompt: Text("Name"))
                        .frame(width: 220)
                        .onSubmit(saveName)
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
            }

            Section("Mitteilungen") {
                PermissionRow(title: "Mitteilungen", allowed: model.notificationsAllowed, request: { Task { await model.requestNotifications() } }, pane: nil)
                if model.notificationsAllowed == true, !model.persistentAlerts {
                    HStack(alignment: .top) {
                        Text("Stell den Stil auf „Hinweise“, damit eine Erinnerung stehen bleibt, bis du „Aufnehmen“ klickst.")
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
}

struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    var title: String
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
                    Text("Systemstandard\(AudioSystem.defaultInputName.map { " (\($0))" } ?? "")").tag(String?.none)
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
                            Text("Geladen").font(.caption).foregroundStyle(.secondary)
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
                            Text("\(step) · \(Int(fraction * 100)) %").font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        HStack {
                            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            Button("Erneut laden") { model.prepareEngine() }
                        }
                    case .idle:
                        Button(model.modelsDownloaded ? "Laden" : "Herunterladen") { model.prepareEngine() }
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
                    Text("Keiner").tag(ProviderKind?.none)
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
        count == 1 ? "1 Modell" : "\(count) Modelle"
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
