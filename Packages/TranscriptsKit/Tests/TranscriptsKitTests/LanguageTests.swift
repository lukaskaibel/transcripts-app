import Foundation
import Testing
@testable import TranscriptsKit

/// Names heard in a conversation, in every language the app speaks.
@Suite struct NameEvidenceLanguageTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var language: String
        /// The speaker introduces themselves as the name.
        var introduction: String
        /// Someone thanks the previous speaker by name.
        var thanks: String
        /// Someone hands over to the next speaker by name.
        var handover: String
        var name: String
        var testDescription: String { language }
    }

    static let cases: [Case] = [
        Case(language: "de", introduction: "Hallo zusammen, ich bin Paula aus dem Support.", thanks: "Danke, Paula.", handover: "Paula, was meinst du?", name: "Paula"),
        Case(language: "en", introduction: "Hi everyone, my name is Paula, I'm with support.", thanks: "Thanks, Paula.", handover: "Paula, what do you think?", name: "Paula"),
        Case(language: "fr", introduction: "Bonjour à tous, je m’appelle Camille, je suis au support.", thanks: "Merci, Camille.", handover: "Camille, qu’en penses-tu ?", name: "Camille"),
        Case(language: "es", introduction: "Hola a todos, me llamo Lucía y trabajo en soporte.", thanks: "Gracias, Lucía.", handover: "Lucía, ¿qué opinas?", name: "Lucía"),
        Case(language: "it", introduction: "Ciao a tutti, mi chiamo Chiara e lavoro al supporto.", thanks: "Grazie, Chiara.", handover: "Chiara, che ne pensi?", name: "Chiara"),
        Case(language: "pt", introduction: "Olá a todos, meu nome é Mariana e trabalho no suporte.", thanks: "Obrigado, Mariana.", handover: "Mariana, o que você acha?", name: "Mariana"),
        Case(language: "nl", introduction: "Hallo allemaal, ik heet Femke en ik werk bij support.", thanks: "Bedankt, Femke.", handover: "Femke, wat vind jij?", name: "Femke"),
        Case(language: "pl", introduction: "Cześć wszystkim, nazywam się Joanna i pracuję w supporcie.", thanks: "Dzięki, Joanna.", handover: "Joanna, co myślisz?", name: "Joanna"),
        Case(language: "ru", introduction: "Всем привет, меня зовут Ирина, я из поддержки.", thanks: "Спасибо, Ирина.", handover: "Ирина, что думаешь?", name: "Ирина"),
        Case(language: "uk", introduction: "Всім привіт, мене звати Оксана, я з підтримки.", thanks: "Дякую, Оксана.", handover: "Оксана, що думаєш?", name: "Оксана"),
    ]

    let finder = NameEvidenceFinder(knownNames: [])

    @Test(arguments: cases) func introductions(_ example: Case) throws {
        let clues = finder.clues(in: [SpokenLine(speakerKey: "S1", text: example.introduction)])
        let clue = try #require(clues.first { $0.kind == .introduction })
        #expect(clue.speakerKey == "S1")
        #expect(clue.name == example.name)
    }

    @Test(arguments: cases) func thanksNameThePreviousSpeaker(_ example: Case) throws {
        let lines = [SpokenLine(speakerKey: "S2", text: "…"), SpokenLine(speakerKey: "S1", text: example.thanks)]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S2")
        #expect(clue.kind == .answeredAfter)
        #expect(clue.name == example.name)
    }

    @Test(arguments: cases) func handoversNameTheNextSpeaker(_ example: Case) throws {
        let lines = [SpokenLine(speakerKey: "S1", text: example.handover), SpokenLine(speakerKey: "S3", text: "…")]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S3")
        #expect(clue.kind == .askedBefore)
        #expect(clue.name == example.name)
    }

    /// Polish, Russian and Ukrainian change a name when someone is called by it; the clue still names the person.
    @Test func calledByAnInflectedFormOfAKnownName() {
        let finder = NameEvidenceFinder(knownNames: ["Anna Nowak", "Tomasz Wiśniewski", "Олена Коваленко", "Маша Иванова"])
        let examples: [(String, String)] = [
            ("Dzięki, Anno.", "Anna"),
            ("Tomaszu, co myślisz?", "Tomasz"),
            ("Дякую, Олено.", "Олена"),
            ("Маш, что думаешь?", "Маша"),
        ]
        for (text, name) in examples {
            let lines = [SpokenLine(speakerKey: "S2", text: "…"), SpokenLine(speakerKey: "S1", text: text), SpokenLine(speakerKey: "S3", text: "…")]
            #expect(finder.clues(in: lines).first?.name == name, "\(text)")
        }
    }

    /// Another first name that merely starts like a known one stays a name of its own.
    @Test func aDifferentNameIsNotAnInflection() {
        let finder = NameEvidenceFinder(knownNames: ["Marc Weber"])
        let lines = [SpokenLine(speakerKey: "S2", text: "…"), SpokenLine(speakerKey: "S1", text: "Danke, Marcel.")]
        #expect(finder.clues(in: lines).first?.name == "Marcel")
    }

    /// "I met Anna yesterday" is no introduction.
    @Test func meetingSomeoneIsNoIntroduction() {
        let clues = NameEvidenceFinder(knownNames: ["Anna Berger"]).clues(in: [SpokenLine(speakerKey: "S1", text: "I met Anna yesterday and we talked about it.")])
        #expect(!clues.contains { $0.kind == .introduction })
    }
}

@Suite struct LocalizationTests {
    @Test func languagesFromCodes() {
        #expect(AppLanguage(code: "pt-PT") == .portuguese)
        #expect(AppLanguage(code: "de_CH") == .german)
        #expect(AppLanguage(code: "uk") == .ukrainian)
        #expect(AppLanguage(code: "ja") == nil)
        #expect(AppLanguage.languages.count == 10)
    }

    /// Outside the app, without its translations, everything stays German.
    @Test func storedTextsShowInGermanWithoutTranslations() {
        #expect(Strings.label("Sprecher 3") == "Sprecher 3")
        #expect(Strings.label(Strings.meLabel) == "Du")
        #expect(Strings.number(inLabel: "Sprecher 12") == 12)
        #expect(SpeakerIdentifier.meetings(inVoiceReason: "Stimme ähnlich wie in einem früheren Meeting") == 1)
        #expect(SpeakerIdentifier.meetings(inVoiceReason: "Stimme ähnlich wie in 4 früheren Meetings") == 4)
        #expect(Strings.reason("Stimme ähnlich wie in 4 früheren Meetings") == "Stimme ähnlich wie in 4 früheren Meetings")
        #expect(Strings.reason("Miriam: „Gute Idee, Jonas.“") == "Miriam: „Gute Idee, Jonas.“")
    }

    @Test func everySummaryLanguageNamesItsLanguage() {
        for language in SummaryLanguage.allCases where language != .meeting {
            #expect(Summarizer.languageRule(language).contains(language.language!.englishName))
        }
        #expect(Summarizer.languageRule(.meeting).isEmpty)
    }
}
