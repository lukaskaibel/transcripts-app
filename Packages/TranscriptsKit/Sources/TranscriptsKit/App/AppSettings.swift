import Foundation
import Observation

public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: String(localized: "Automatisch")
        case .light: String(localized: "Hell", comment: "appearance: light")
        case .dark: String(localized: "Dunkel", comment: "appearance: dark")
        }
    }
}

public enum VoiceStrictness: String, CaseIterable, Identifiable, Sendable {
    case strict, standard, relaxed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .strict: String(localized: "Vorsichtig", comment: "how readily voices are matched to people: cautious")
        case .standard: String(localized: "Ausgewogen", comment: "how readily voices are matched to people: balanced")
        case .relaxed: String(localized: "Großzügig", comment: "how readily voices are matched to people: generous")
        }
    }
    public var detail: String {
        switch self {
        case .strict: String(localized: "Ordnet Stimmen nur bei sehr hoher Sicherheit selbst zu.")
        case .standard: String(localized: "Empfohlen für die meisten Meetings.")
        case .relaxed: String(localized: "Schlägt öfter vor, irrt sich aber auch öfter.")
        }
    }
    public var thresholds: VoiceThresholds {
        switch self {
        case .strict: .strict
        case .standard: .standard
        case .relaxed: .relaxed
        }
    }
}

public enum AudioRetention: String, CaseIterable, Identifiable, Sendable {
    case forever, month, never
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .forever: String(localized: "Immer behalten", comment: "what happens to a meeting's audio recording")
        case .month: String(localized: "30 Tage behalten", comment: "what happens to a meeting's audio recording")
        case .never: String(localized: "Nach dem Transkribieren löschen")
        }
    }
}

public enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    case meeting, german, english, french, spanish, italian, portuguese, dutch, polish, russian, ukrainian
    public var id: String { rawValue }

    /// The language every summary is written in, or nil for the language of each meeting.
    public var language: AppLanguage? {
        switch self {
        case .meeting: nil
        case .german: .german
        case .english: .english
        case .french: .french
        case .spanish: .spanish
        case .italian: .italian
        case .portuguese: .portuguese
        case .dutch: .dutch
        case .polish: .polish
        case .russian: .russian
        case .ukrainian: .ukrainian
        }
    }

    public var title: String { language?.nativeName ?? String(localized: "Wie das Meeting") }
}

/// The user's preferences, kept in UserDefaults.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingDone = defaults.bool(forKey: Keys.onboardingDone)
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        appIcon = AppIconChoice(rawValue: defaults.string(forKey: Keys.appIcon) ?? "") ?? .automatic
        autoSummarize = defaults.object(forKey: Keys.autoSummarize) as? Bool ?? true
        summaryProvider = ProviderKind(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "")
        summaryLanguage = SummaryLanguage(rawValue: defaults.string(forKey: Keys.summaryLanguage) ?? "") ?? .meeting
        liveSummary = defaults.bool(forKey: Keys.liveSummary)
        ollamaURL = defaults.string(forKey: Keys.ollamaURL) ?? OllamaProvider.defaultURL.absoluteString
        transcriptionModel = TranscriptionModel(rawValue: defaults.string(forKey: Keys.transcriptionModel) ?? "") ?? .ultra
        microphoneUID = defaults.string(forKey: Keys.microphoneUID)
        captureSystemAudio = defaults.object(forKey: Keys.captureSystemAudio) as? Bool ?? true
        floatingRecorder = defaults.object(forKey: Keys.floatingRecorder) as? Bool ?? true
        openLiveWindow = defaults.object(forKey: Keys.openLiveWindow) as? Bool ?? false
        calendarReminders = defaults.object(forKey: Keys.calendarReminders) as? Bool ?? true
        reminderLead = defaults.object(forKey: Keys.reminderLead) as? Double ?? 60
        detectCalls = defaults.object(forKey: Keys.detectCalls) as? Bool ?? true
        onlyMyMeetings = defaults.object(forKey: Keys.onlyMyMeetings) as? Bool ?? true
        hiddenMeetings = defaults.data(forKey: Keys.hiddenMeetings).flatMap { try? JSONDecoder().decode([HiddenCalendarItem].self, from: $0) } ?? []
        voiceStrictness = VoiceStrictness(rawValue: defaults.string(forKey: Keys.voiceStrictness) ?? "") ?? .standard
        learnVoices = defaults.object(forKey: Keys.learnVoices) as? Bool ?? true
        audioRetention = AudioRetention(rawValue: defaults.string(forKey: Keys.audioRetention) ?? "") ?? .forever
        hideDockIcon = defaults.object(forKey: Keys.hideDockIcon) as? Bool ?? true
        githubLogin = GitHubLoginMethod(rawValue: defaults.string(forKey: Keys.githubLogin) ?? "")
        githubSuggestLabels = defaults.object(forKey: Keys.githubSuggestLabels) as? Bool ?? true
        githubIncludeContext = defaults.object(forKey: Keys.githubIncludeContext) as? Bool ?? true
        githubAskAfterSummary = defaults.object(forKey: Keys.githubAskAfterSummary) as? Bool ?? true
        if let since = defaults.object(forKey: Keys.inboxSince) as? Date {
            inboxSince = since
        } else {
            // What happened before the inbox existed is known already.
            let now = Date()
            defaults.set(now, forKey: Keys.inboxSince)
            inboxSince = now
        }
        openedSummaries = defaults.data(forKey: Keys.openedSummaries).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        inboxDismissed = Set(defaults.stringArray(forKey: Keys.inboxDismissed) ?? [])
        if let data = defaults.data(forKey: Keys.models), let models = try? JSONDecoder().decode([String: String].self, from: data) {
            summaryModels = models
        } else {
            summaryModels = [:]
        }
    }

    enum Keys {
        static let onboardingDone = "onboardingDone"
        static let appearance = "appearance"
        static let appIcon = "appIcon"
        static let autoSummarize = "autoSummarize"
        static let summaryProvider = "summaryProvider"
        static let summaryLanguage = "summaryLanguage"
        static let liveSummary = "liveSummary"
        static let ollamaURL = "ollamaURL"
        static let transcriptionModel = "transcriptionModel"
        static let microphoneUID = "microphoneUID"
        static let captureSystemAudio = "captureSystemAudio"
        static let floatingRecorder = "floatingRecorder"
        static let openLiveWindow = "openLiveWindow"
        static let calendarReminders = "calendarReminders"
        static let reminderLead = "reminderLead"
        static let detectCalls = "detectCalls"
        static let onlyMyMeetings = "onlyMyMeetings"
        static let hiddenMeetings = "hiddenMeetings"
        static let inboxSince = "inboxSince"
        static let openedSummaries = "openedSummaries"
        static let inboxDismissed = "inboxDismissed"
        static let voiceStrictness = "voiceStrictness"
        static let learnVoices = "learnVoices"
        static let audioRetention = "audioRetention"
        static let hideDockIcon = "hideDockIcon"
        static let models = "summaryModels"
        static let callTracksChecked = "callTracksChecked"
        static let githubLogin = "githubLogin"
        static let githubSuggestLabels = "githubSuggestLabels"
        static let githubIncludeContext = "githubIncludeContext"
        static let githubAskAfterSummary = "githubAskAfterSummary"
    }

    public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Keys.onboardingDone) } }
    public var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    public var appIcon: AppIconChoice { didSet { defaults.set(appIcon.rawValue, forKey: Keys.appIcon) } }
    /// Write a summary as soon as a transcript is ready.
    public var autoSummarize: Bool { didSet { defaults.set(autoSummarize, forKey: Keys.autoSummarize) } }
    /// The service that writes summaries; nil until one is set up.
    public var summaryProvider: ProviderKind? { didSet { defaults.set(summaryProvider?.rawValue, forKey: Keys.summaryProvider) } }
    public var summaryLanguage: SummaryLanguage { didSet { defaults.set(summaryLanguage.rawValue, forKey: Keys.summaryLanguage) } }
    /// The chosen model per provider.
    public var summaryModels: [String: String] {
        didSet { defaults.set(try? JSONEncoder().encode(summaryModels), forKey: Keys.models) }
    }
    /// Keep a running summary next to the live transcript (one request every minute and a half).
    public var liveSummary: Bool { didSet { defaults.set(liveSummary, forKey: Keys.liveSummary) } }
    public var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: Keys.ollamaURL) } }
    public var transcriptionModel: TranscriptionModel { didSet { defaults.set(transcriptionModel.rawValue, forKey: Keys.transcriptionModel) } }
    public var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: Keys.microphoneUID) } }
    public var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Keys.captureSystemAudio) } }
    public var floatingRecorder: Bool { didSet { defaults.set(floatingRecorder, forKey: Keys.floatingRecorder) } }
    public var openLiveWindow: Bool { didSet { defaults.set(openLiveWindow, forKey: Keys.openLiveWindow) } }
    public var calendarReminders: Bool { didSet { defaults.set(calendarReminders, forKey: Keys.calendarReminders) } }
    /// Seconds before the start a reminder appears.
    public var reminderLead: Double { didSet { defaults.set(reminderLead, forKey: Keys.reminderLead) } }
    public var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: Keys.detectCalls) } }
    /// Leave out calendar events with guests the user isn't among (see `MeetingFilter.onlyMine`).
    public var onlyMyMeetings: Bool { didSet { defaults.set(onlyMyMeetings, forKey: Keys.onlyMyMeetings) } }
    /// Meetings and calendars the user said aren't theirs, newest last.
    public var hiddenMeetings: [HiddenCalendarItem] {
        didSet { defaults.set(try? JSONEncoder().encode(hiddenMeetings), forKey: Keys.hiddenMeetings) }
    }
    /// Summaries and tasks from before this moment don't show up in the inbox.
    public var inboxSince: Date { didSet { defaults.set(inboxSince, forKey: Keys.inboxSince) } }
    /// When the user last saw each meeting's summary.
    public var openedSummaries: [String: Date] {
        didSet { defaults.set(try? JSONEncoder().encode(openedSummaries), forKey: Keys.openedSummaries) }
    }
    /// Inbox entries the user put aside ("github:<meeting id>").
    public var inboxDismissed: Set<String> { didSet { defaults.set(Array(inboxDismissed).sorted(), forKey: Keys.inboxDismissed) } }
    public var voiceStrictness: VoiceStrictness { didSet { defaults.set(voiceStrictness.rawValue, forKey: Keys.voiceStrictness) } }
    public var learnVoices: Bool { didSet { defaults.set(learnVoices, forKey: Keys.learnVoices) } }
    public var audioRetention: AudioRetention { didSet { defaults.set(audioRetention.rawValue, forKey: Keys.audioRetention) } }
    /// Without an open window the app lives only in the menu bar.
    public var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: Keys.hideDockIcon) } }
    /// How the app signs in to GitHub; nil until connected.
    public var githubLogin: GitHubLoginMethod? { didSet { defaults.set(githubLogin?.rawValue, forKey: Keys.githubLogin) } }
    /// Let the summary's language model pick labels and write a short description for new issues.
    public var githubSuggestLabels: Bool { didSet { defaults.set(githubSuggestLabels, forKey: Keys.githubSuggestLabels) } }
    /// New issues get context and a quote from the transcript (never in public repositories).
    public var githubIncludeContext: Bool { didSet { defaults.set(githubIncludeContext, forKey: Keys.githubIncludeContext) } }
    /// After a summary, offer to create the tasks in their remembered place with a notification.
    public var githubAskAfterSummary: Bool { didSet { defaults.set(githubAskAfterSummary, forKey: Keys.githubAskAfterSummary) } }

    /// The recordings made before the call track was read at the device's rate were checked and repaired
    /// (see `CallTrackRepair`). Not observed: only the one-time maintenance reads it.
    @ObservationIgnored public var callTracksChecked: Bool {
        get { defaults.bool(forKey: Keys.callTracksChecked) }
        set { defaults.set(newValue, forKey: Keys.callTracksChecked) }
    }

    public func model(for provider: ProviderKind) -> String? {
        summaryModels[provider.rawValue]
    }

    public func setModel(_ model: String?, for provider: ProviderKind) {
        summaryModels[provider.rawValue] = model
    }
}
