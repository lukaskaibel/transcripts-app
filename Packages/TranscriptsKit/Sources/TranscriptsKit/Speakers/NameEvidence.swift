import Foundation
import NaturalLanguage

/// A line of a transcript as the name finder sees it.
public struct SpokenLine: Equatable, Sendable {
    public var speakerKey: String
    public var text: String

    public init(speakerKey: String, text: String) {
        self.speakerKey = speakerKey
        self.text = text
    }
}

/// A hint, taken from what was said, that a voice belongs to a certain name.
public struct NameClue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// "Hi, ich bin Anna" — the speaker named themselves.
        case introduction
        /// "Thomas, was meinst du?" — the next speaker was asked by name.
        case askedBefore
        /// "Gute Idee, Jonas." — the previous speaker was answered by name.
        case answeredAfter
        /// The language model inferred it from the whole conversation.
        case assistant
    }

    public var speakerKey: String
    public var name: String
    public var kind: Kind
    /// The sentence the clue comes from.
    public var quote: String
    /// Who said the quote.
    public var quoteSpeakerKey: String

    public init(speakerKey: String, name: String, kind: Kind, quote: String, quoteSpeakerKey: String) {
        self.speakerKey = speakerKey
        self.name = name
        self.kind = kind
        self.quote = quote
        self.quoteSpeakerKey = quoteSpeakerKey
    }

    public var weight: Double {
        switch kind {
        case .introduction: 3
        case .assistant: 2
        case .askedBefore: 1.5
        case .answeredAfter: 1.2
        }
    }
}

/// The name a voice most likely has, with the clue that speaks for it most strongly.
public struct NameGuess: Equatable, Sendable {
    public var name: String
    public var score: Double
    public var bestClue: NameClue
}

/// Finds names in a conversation and works out whose they are.
///
/// Three patterns carry most of the signal in meetings: people introduce themselves ("ich bin …",
/// "… hier"), hand over with a name ("Thomas, was meinst du?" — the next speaker is Thomas), and
/// answer with a name ("Danke, Jonas." — the previous speaker was Jonas). Words count as names when
/// they belong to someone known (the voice library or the calendar invitees), are common first names,
/// or are tagged as personal names by Apple's NaturalLanguage framework.
public struct NameEvidenceFinder {
    public var knownNames: [String]

    public init(knownNames: [String] = []) {
        self.knownNames = knownNames
        knownTokens = Set(knownNames.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
    }

    private let knownTokens: Set<String>

    private static let name = #"(\p{Lu}[\p{L}’'-]{1,30}(?:\s\p{Lu}[\p{L}’'-]{1,30})?)"#
    private static let firstName = #"(\p{Lu}[\p{L}’'-]{1,30})"#

    private static let introductions: [NSRegularExpression] = [
        #"\b(?:ich heiße|ich heisse|mein name ist|my name is|i am called)\s+"# + name,
        #"\b(?:ich bin|i'm|i am|hier ist|hier spricht|this is|it's)\s+(?:der |die |also |einfach |nur )?"# + name,
        #"^(?:(?:hallo|hi|hey|servus|moin|guten (?:morgen|tag|abend)|hello)[,!.]?\s+)?(?:zusammen[,!.]?\s+)?"# + firstName + #"\s+(?:hier|here|speaking)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Strong introductions name someone even when the word is unknown ("mein Name ist Xaver").
    private static let strongIntroductionIndex = 0

    private static let leadingVocative = try! NSRegularExpression(
        pattern: #"^(?:(?:also|ok(?:ay)?|ja|gut|danke|genau|super|prima|hallo|hi|hey|thanks|thank you|great|right|so|und)[,!]?\s+)?"# + firstName + #"\s*[,:]\s+\S"#,
        options: [.caseInsensitive]
    )
    private static let trailingVocative = try! NSRegularExpression(
        pattern: #",\s*"# + firstName + #"\s*[.?!…]*\s*$"#,
        options: []
    )
    private static let thanks = try! NSRegularExpression(
        pattern: #"\b(?:danke(?:\s+dir)?|vielen dank|dank dir|merci|thanks|thank you|willkommen|welcome)[,!]?\s+"# + firstName + #"\b"#,
        options: [.caseInsensitive]
    )
    /// "Gute Idee, Jonas, ich mache …" — an answer with a name in the middle of the sentence.
    private static let acknowledgedByName = try! NSRegularExpression(
        pattern: #"\b(?:gute idee|guter punkt|genau|stimmt|richtig|super|prima|klasse|einverstanden|good point|good idea|exactly|right|agreed|great)[,!]?\s+"# + firstName + #"\s*[,.!?]"#,
        options: [.caseInsensitive]
    )

    private static let handover = [
        "?", "was meinst du", "was denkst du", "was sagst du", "magst du", "kannst du", "willst du", "möchtest du",
        "übernimmst du", "würdest du", "hast du", "bist du", "du bist dran", "dein punkt", "bitte",
        "what do you think", "can you", "could you", "would you", "will you", "go ahead", "your turn", "over to you",
    ]
    private static let acknowledgement = [
        "danke", "dank dir", "merci", "gute idee", "guter punkt", "genau", "stimmt", "richtig", "super", "prima",
        "willkommen", "einverstanden", "thanks", "thank you", "good point", "good idea", "right", "exactly", "welcome",
        "agreed",
    ]

    /// Words that look like names in these positions but aren't.
    private static let notNames: Set<String> = [
        "leute", "zusammen", "alle", "team", "freunde", "kollegen", "kolleginnen", "danke", "okay", "ok", "ja", "nein",
        "gut", "super", "genau", "also", "hallo", "hi", "hey", "frage", "punkt", "sache", "meinung", "moment", "ende",
        "everyone", "guys", "folks", "all", "team", "thanks", "yes", "no", "right", "sorry", "great", "good", "okay",
        "jetzt", "hier", "da", "dabei", "dran", "fertig", "sicher", "froh", "gespannt", "neu", "raus", "weg", "zurück",
        "the", "a", "an", "just", "not", "so", "also", "here", "there", "back", "done", "sure", "glad", "new", "in",
        "der", "die", "das", "ein", "eine", "einer", "nicht", "noch", "schon", "auch", "nur", "mal", "eigentlich",
    ]

    public func clues(in lines: [SpokenLine]) -> [NameClue] {
        var clues: [NameClue] = []
        for (index, line) in lines.enumerated() {
            for sentence in Self.sentences(in: line.text) {
                clues += introductionClues(in: sentence, line: line)
                clues += addressClues(in: sentence, lineIndex: index, lines: lines)
            }
        }
        return clues
    }

    /// Names a speaker gives for themselves in `text` ("hier ist Paula").
    public func introducedNames(in text: String) -> [String] {
        Self.sentences(in: text).flatMap { sentence in
            introductionClues(in: sentence, line: SpokenLine(speakerKey: "", text: sentence)).map(\.name)
        }
    }

    /// Adds up the clues per voice and name.
    public static func guesses(from clues: [NameClue]) -> [String: [NameGuess]] {
        var result: [String: [NameGuess]] = [:]
        for (speaker, speakerClues) in Dictionary(grouping: clues, by: \.speakerKey) {
            let byName = Dictionary(grouping: speakerClues) { normalizedName($0.name) }
            let guesses = byName.values.compactMap { group -> NameGuess? in
                guard let best = group.max(by: { $0.weight < $1.weight }) else { return nil }
                // The fullest spelling seen ("Anna Berger" over "Anna").
                let name = group.map(\.name).max(by: { $0.count < $1.count }) ?? best.name
                return NameGuess(name: name, score: group.reduce(0) { $0 + $1.weight }, bestClue: best)
            }
            result[speaker] = guesses.sorted { $0.score > $1.score }
        }
        return result
    }

    public static func normalizedName(_ name: String) -> String {
        name.split(separator: " ").first.map { $0.lowercased() } ?? name.lowercased()
    }

    // MARK: Patterns

    private func introductionClues(in sentence: String, line: SpokenLine) -> [NameClue] {
        var clues: [NameClue] = []
        for (index, regex) in Self.introductions.enumerated() {
            for match in Self.matches(regex, in: sentence) {
                guard let candidate = Self.capture(match, in: sentence) else { continue }
                let name = trimmedName(candidate, strong: index == Self.strongIntroductionIndex, context: sentence)
                guard let name else { continue }
                clues.append(NameClue(speakerKey: line.speakerKey, name: name, kind: .introduction, quote: sentence, quoteSpeakerKey: line.speakerKey))
            }
        }
        return clues
    }

    private func addressClues(in sentence: String, lineIndex: Int, lines: [SpokenLine]) -> [NameClue] {
        let line = lines[lineIndex]
        let lowered = sentence.lowercased()
        var names: [String] = []
        for regex in [Self.leadingVocative, Self.trailingVocative, Self.thanks, Self.acknowledgedByName] {
            for match in Self.matches(regex, in: sentence) {
                if let candidate = Self.capture(match, in: sentence), let name = trimmedName(candidate, strong: false, context: sentence) {
                    names.append(name)
                }
            }
        }
        guard !names.isEmpty else { return [] }

        let isAcknowledgement = Self.acknowledgement.contains { lowered.contains($0) }
        let isHandover = !isAcknowledgement && Self.handover.contains { lowered.contains($0) }
        var clues: [NameClue] = []
        for name in Set(names) {
            if isAcknowledgement, let previous = Self.neighbour(of: lineIndex, in: lines, step: -1) {
                clues.append(NameClue(speakerKey: previous.speakerKey, name: name, kind: .answeredAfter, quote: sentence, quoteSpeakerKey: line.speakerKey))
            } else if isHandover, let next = Self.neighbour(of: lineIndex, in: lines, step: 1) {
                clues.append(NameClue(speakerKey: next.speakerKey, name: name, kind: .askedBefore, quote: sentence, quoteSpeakerKey: line.speakerKey))
            }
        }
        return clues
    }

    /// The nearest line in `step` direction by somebody else.
    private static func neighbour(of index: Int, in lines: [SpokenLine], step: Int) -> SpokenLine? {
        let speaker = lines[index].speakerKey
        var position = index + step
        while position >= 0, position < lines.count {
            if lines[position].speakerKey != speaker { return lines[position] }
            // Only look past the same speaker's own continuation, not across other people.
            position += step
            if abs(position - index) > 3 { break }
        }
        return nil
    }

    /// Keeps the candidate if it is plausibly a name, trimming a trailing word that isn't.
    private func trimmedName(_ candidate: String, strong: Bool, context: String) -> String? {
        var parts = candidate.split(separator: " ").map(String.init)
        while let last = parts.last, parts.count > 1, !isName(last, strong: false, context: context) || Self.notNames.contains(last.lowercased()) {
            parts.removeLast()
        }
        guard let first = parts.first, !Self.notNames.contains(first.lowercased()) else { return nil }
        guard isName(first, strong: strong, context: context) else { return nil }
        return parts.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "’'-"))
    }

    private func isName(_ word: String, strong: Bool, context: String) -> Bool {
        let lowered = word.lowercased()
        guard word.first?.isUppercase == true, !Self.notNames.contains(lowered) else { return false }
        if knownTokens.contains(lowered) || FirstNames.common.contains(lowered) { return true }
        if strong { return true }
        return Self.taggedAsPersonalName(word, in: context)
    }

    private static func taggedAsPersonalName(_ word: String, in sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        var found = false
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, sentence[range].split(separator: " ").contains(where: { $0 == word }) {
                found = true
                return false
            }
            return true
        }
        return found
    }

    // MARK: Text helpers

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [text] : result
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    private static func capture(_ match: NSTextCheckingResult, in text: String) -> String? {
        guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Common first names across the languages people in German-speaking offices tend to have.
enum FirstNames {
    static let common: Set<String> = Set("""
    aaron adam adrian ahmed aisha alan albert alex alexa alexander alexandra alexei ali alice alicia alina alisa \
    amelie amir amy ana andi andre andrea andreas andrei andrew andy angela angelika anja anke ann anna annabel \
    anne annika anton antonia arne arthur aylin ayse barbara bastian beate ben benedikt benjamin bernd bernhard \
    bert bettina bianca birgit bjoern björn boris brian bruno can carina carl carla carlos carmen carolin caroline \
    charlotte chris christian christina christine christoph christopher claudia clara conrad constantin cornelia \
    dag daniel daniela dario david deniz dennis diana dieter dimitri dirk dominik doris elena eli elias elif elisa \
    elisabeth elke ella ellen emil emilia emily emma emre eric erik esra eva fabian fatima felix finn florian \
    franz franziska frank frederik friedrich gabriel gabriele georg george gerhard gina giulia greta gregor guido \
    günter hanna hannah hannes hans harald heike heiko heinz helena helga helmut hendrik henrik henry herbert \
    hugo ibrahim ida igor ilona ina ines ingo ingrid irina isabel isabella ivan jakob jamal jan jana janina janik \
    janis jannik jasmin jason jens jessica jochen joe johann johanna johannes jonas jonathan jörg josef joseph \
    josephine judith jule julia julian juliane julius jürgen justus kai karin karl karla karolina katarina \
    katharina kathrin katja kemal kerstin kevin kim klara klaus konrad konstantin kristina lara lars laura lea \
    lena lennart leo leon leonie lina linda lisa lorenz lotta louis luca lucas lucia ludwig luis luisa lukas \
    luke lydia magdalena maike malte manfred manuel manuela marc marcel marco marcus maren maria marie marina \
    mario marion marius mark markus marlene martha martin martina mathias matteo matthias max maximilian maya \
    mehmet melanie melina melissa mia michael michaela michelle mike milan mila miriam mohamed mohammed moritz \
    nadine nadja natalie nathalie nick nico nicolas nicole niklas niko nikolai nils nina noah noemi nora olaf \
    ole oliver olga omar oscar oskar pascal patricia patrick paul paula pauline peter petra philipp philip pia \
    rafael ralf ramona raphael rebecca regina reinhard renate rene robert robin roland roman ronja rosa ruth sabine \
    sabrina sam samira samuel sandra sara sarah sascha sebastian selin sergej silke simon simone sofia sophia \
    sophie stefan stefanie stephan steffen stella sven svenja tamara tanja thea theo thomas thorsten tim timo \
    tina tobias tom tomas torsten uwe ulrich ute valentin valentina vanessa vera verena victor viktor viktoria \
    vincent volker walter werner wolfgang xaver yannick yasmin yusuf zoe zeynep
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}
