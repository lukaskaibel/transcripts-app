import Foundation
import Observation

public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Automatisch"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }
}

public enum VoiceStrictness: String, CaseIterable, Identifiable, Sendable {
    case strict, standard, relaxed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .strict: "Vorsichtig"
        case .standard: "Ausgewogen"
        case .relaxed: "Großzügig"
        }
    }
    public var detail: String {
        switch self {
        case .strict: "Ordnet Stimmen nur bei sehr hoher Sicherheit selbst zu."
        case .standard: "Empfohlen für die meisten Meetings."
        case .relaxed: "Schlägt öfter vor, irrt sich aber auch öfter."
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
        case .forever: "Immer behalten"
        case .month: "30 Tage behalten"
        case .never: "Nach dem Transkribieren löschen"
        }
    }
}

public enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    case meeting, german, english
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .meeting: "Wie das Meeting"
        case .german: "Deutsch"
        case .english: "Englisch"
        }
    }
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
        echoCancellation = defaults.bool(forKey: Keys.echoCancellation)
        captureSystemAudio = defaults.object(forKey: Keys.captureSystemAudio) as? Bool ?? true
        floatingRecorder = defaults.object(forKey: Keys.floatingRecorder) as? Bool ?? true
        openLiveWindow = defaults.object(forKey: Keys.openLiveWindow) as? Bool ?? false
        calendarReminders = defaults.object(forKey: Keys.calendarReminders) as? Bool ?? true
        reminderLead = defaults.object(forKey: Keys.reminderLead) as? Double ?? 60
        detectCalls = defaults.object(forKey: Keys.detectCalls) as? Bool ?? true
        voiceStrictness = VoiceStrictness(rawValue: defaults.string(forKey: Keys.voiceStrictness) ?? "") ?? .standard
        learnVoices = defaults.object(forKey: Keys.learnVoices) as? Bool ?? true
        audioRetention = AudioRetention(rawValue: defaults.string(forKey: Keys.audioRetention) ?? "") ?? .forever
        hideDockIcon = defaults.object(forKey: Keys.hideDockIcon) as? Bool ?? true
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
        static let echoCancellation = "echoCancellation"
        static let captureSystemAudio = "captureSystemAudio"
        static let floatingRecorder = "floatingRecorder"
        static let openLiveWindow = "openLiveWindow"
        static let calendarReminders = "calendarReminders"
        static let reminderLead = "reminderLead"
        static let detectCalls = "detectCalls"
        static let voiceStrictness = "voiceStrictness"
        static let learnVoices = "learnVoices"
        static let audioRetention = "audioRetention"
        static let hideDockIcon = "hideDockIcon"
        static let models = "summaryModels"
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
    public var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: Keys.echoCancellation) } }
    public var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: Keys.captureSystemAudio) } }
    public var floatingRecorder: Bool { didSet { defaults.set(floatingRecorder, forKey: Keys.floatingRecorder) } }
    public var openLiveWindow: Bool { didSet { defaults.set(openLiveWindow, forKey: Keys.openLiveWindow) } }
    public var calendarReminders: Bool { didSet { defaults.set(calendarReminders, forKey: Keys.calendarReminders) } }
    /// Seconds before the start a reminder appears.
    public var reminderLead: Double { didSet { defaults.set(reminderLead, forKey: Keys.reminderLead) } }
    public var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: Keys.detectCalls) } }
    public var voiceStrictness: VoiceStrictness { didSet { defaults.set(voiceStrictness.rawValue, forKey: Keys.voiceStrictness) } }
    public var learnVoices: Bool { didSet { defaults.set(learnVoices, forKey: Keys.learnVoices) } }
    public var audioRetention: AudioRetention { didSet { defaults.set(audioRetention.rawValue, forKey: Keys.audioRetention) } }
    /// Without an open window the app lives only in the menu bar.
    public var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: Keys.hideDockIcon) } }

    public func model(for provider: ProviderKind) -> String? {
        summaryModels[provider.rawValue]
    }

    public func setModel(_ model: String?, for provider: ProviderKind) {
        summaryModels[provider.rawValue] = model
    }
}
