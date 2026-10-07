import Foundation

/// The languages the app speaks.
///
/// Only those that both halves of the app handle well: Parakeet v3 transcribes them with less than 8 % of the
/// words wrong (FLEURS: Italian 3.0, Spanish 3.5, Portuguese 4.8, English 4.9, German 5.0, French 5.2, Russian 5.5,
/// Ukrainian 6.8, Polish 7.3, Dutch 7.5; the next, Slovak, is at 8.8 and the rest at 11 to 24), and the voice
/// models (pyannote segmentation, WeSpeaker embeddings) work on the sound of a voice, whatever the language. The
/// names heard in a conversation are found in each of them too (`NameEvidenceFinder`).
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Whatever macOS prefers, among the languages below (English when it prefers none of them).
    case system
    case german = "de"
    case english = "en"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt-BR"
    case dutch = "nl"
    case polish = "pl"
    case russian = "ru"
    case ukrainian = "uk"

    public var id: String { rawValue }

    /// The real languages, without `.system`.
    public static var languages: [AppLanguage] { allCases.filter { $0 != .system } }

    /// The language's name in that language ("Français"), as language menus show it.
    public var nativeName: String {
        switch self {
        case .system: String(localized: "Wie das System")
        case .german: "Deutsch"
        case .english: "English"
        case .french: "Français"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .dutch: "Nederlands"
        case .polish: "Polski"
        case .russian: "Русский"
        case .ukrainian: "Українська"
        }
    }

    /// The name a language model understands in an instruction ("Write in French").
    public var englishName: String {
        switch self {
        case .system: AppLanguage.current.englishName
        case .german: "German"
        case .english: "English"
        case .french: "French"
        case .spanish: "Spanish"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .dutch: "Dutch"
        case .polish: "Polish"
        case .russian: "Russian"
        case .ukrainian: "Ukrainian"
        }
    }

    /// The language code alone ("pt" for Brazilian Portuguese), as speech and text tools use it.
    public var code: String { String(rawValue.prefix(2)) }

    public init?(code: String) {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
        guard let match = Self.languages.first(where: { $0.code == base }) else { return nil }
        self = match
    }

    /// The language the interface shows right now. Without the app's translations around (the command-line tool,
    /// tests) that is German, the language the texts are written in.
    public static var current: AppLanguage {
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        guard available.count > 1, let first = Bundle.main.preferredLocalizations.first else { return .german }
        return AppLanguage(code: first) ?? .english
    }

    /// The language picked in Settings, or `.system`. Only this app's own setting counts, not the system's list.
    public static func chosen(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let identifier = Bundle.main.bundleIdentifier,
              let languages = defaults.persistentDomain(forName: identifier)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        return AppLanguage(code: first) ?? .system
    }

    /// Makes `language` the interface language from the next start on.
    public static func choose(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

public enum AppLocale {
    /// Dates and numbers in the interface's language, with the user's region (24-hour clock, first weekday, …).
    public static var current: Locale {
        let language = AppLanguage.current
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language.rawValue)
        return Locale(components: components)
    }
}
