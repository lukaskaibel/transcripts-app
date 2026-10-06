import Foundation
import Testing
@testable import TranscriptsKit

private func voice(_ seed: Int) -> [Float] {
    var generator = SeededGenerator(seed: UInt64(seed))
    return VoiceMath.normalized((0..<256).map { _ in Float.random(in: -1...1, using: &generator) })
}

/// A voice close to `base`: noise of `amount` relative to the size of one component of a unit vector.
private func near(_ base: [Float], _ amount: Float, seed: Int) -> [Float] {
    var generator = SeededGenerator(seed: UInt64(seed))
    let component: Float = 1 / 16  // 1 / sqrt(256)
    return VoiceMath.normalized(base.map { $0 + Float.random(in: -amount...amount, using: &generator) * component * 4 })
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct VoiceMathTests {
    @Test func cosineOfSameVectorIsOne() {
        let a = voice(1)
        #expect(abs(VoiceMath.cosine(a, a) - 1) < 1e-5)
    }

    @Test func cosineOfUnrelatedVectorsIsSmall() {
        #expect(abs(VoiceMath.cosine(voice(1), voice(2))) < 0.25)
    }

    @Test func cosineOfDifferentLengthsIsZero() {
        #expect(VoiceMath.cosine([1, 0], [1, 0, 0]) == 0)
    }

    @Test func weightedMeanLeansTowardsHeavierVector() throws {
        let a = voice(1), b = voice(2)
        let parts: [([Float], Float)] = [(a, 3), (b, 1)]
        let mean = try #require(VoiceMath.weightedMean(parts))
        #expect(VoiceMath.cosine(mean, a) > VoiceMath.cosine(mean, b))
        #expect(abs(VoiceMath.cosine(mean, mean) - 1) < 1e-5)
    }

    @Test func weightedMeanOfNothingIsNil() {
        #expect(VoiceMath.weightedMean([]) == nil)
    }

    @Test func embeddingDataRoundTrips() {
        let a = voice(7)
        #expect([Float](embeddingData: a.embeddingData) == a)
    }
}

@Suite struct VoiceLibraryTests {
    @Test func ranksTheMatchingPersonFirst() throws {
        let anna = voice(10), thomas = voice(11)
        let library = VoiceLibrary(voices: ["anna": [anna, near(anna, 0.1, seed: 1)], "thomas": [thomas]])
        let matches = library.rank(near(anna, 0.15, seed: 2))
        let best = try #require(matches.first)
        #expect(best.personId == "anna")
        #expect(best.similarity > 0.8)
        #expect(matches[1].similarity < 0.3)
    }

    @Test func boostHelpsInvitees() throws {
        let a = voice(20)
        let library = VoiceLibrary(voices: ["x": [a], "y": [a]])
        let matches = library.rank(a, boosted: ["y"])
        #expect(matches.first?.personId == "y")
    }

    @Test func excludedPeopleAreLeftOut() {
        let a = voice(21)
        let library = VoiceLibrary(voices: ["me": [a], "other": [voice(22)]])
        #expect(!library.rank(a, excluding: ["me"]).contains { $0.personId == "me" })
    }
}

@Suite struct LiveSpeakerTrackerTests {
    @Test func groupsUtterancesByVoice() {
        let anna = voice(30), thomas = voice(31)
        var tracker = LiveSpeakerTracker()
        let first = tracker.assign(near(anna, 0.2, seed: 1), duration: 4)
        let second = tracker.assign(near(thomas, 0.2, seed: 2), duration: 3)
        let third = tracker.assign(near(anna, 0.2, seed: 3), duration: 5)
        let fourth = tracker.assign(near(thomas, 0.2, seed: 4), duration: 2)
        #expect(first == "S1")
        #expect(second == "S2")
        #expect(third == "S1")
        #expect(fourth == "S2")
        #expect(tracker.voices.count == 2)
    }
}

@Suite struct NameEvidenceTests {
    let finder = NameEvidenceFinder(knownNames: ["Anna Berger", "Thomas Klein", "Miriam Okafor", "Jonas Weber"])

    @Test func selfIntroductionNamesTheSpeaker() throws {
        let clues = finder.clues(in: [SpokenLine(speakerKey: "S4", text: "Hallo zusammen, sorry für die Verspätung – hier ist Paula aus dem Support.")])
        let clue = try #require(clues.first)
        #expect(clue.speakerKey == "S4")
        #expect(clue.name == "Paula")
        #expect(clue.kind == .introduction)
    }

    @Test func myNameIsIntroductionAcceptsUnknownNames() throws {
        let clues = finder.clues(in: [SpokenLine(speakerKey: "S1", text: "Mein Name ist Xaver Huber, ich komme vom Einkauf.")])
        #expect(clues.first?.name == "Xaver Huber")
    }

    @Test func questionWithNameNamesTheNextSpeaker() throws {
        let lines = [
            SpokenLine(speakerKey: "S1", text: "Dann verschieben wir auf den 14.? Thomas, passt das für dich?"),
            SpokenLine(speakerKey: "S2", text: "Ja, der 14. ist realistisch."),
        ]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S2")
        #expect(clue.name == "Thomas")
        #expect(clue.kind == .askedBefore)
        #expect(clue.quoteSpeakerKey == "S1")
    }

    @Test func thanksWithNameNamesThePreviousSpeaker() throws {
        let lines = [
            SpokenLine(speakerKey: "S4", text: "Wir könnten die Firmendaten optional machen."),
            SpokenLine(speakerKey: "S3", text: "Gute Idee, Jonas. Ich mach bis Mittwoch einen Entwurf dafür."),
        ]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S4")
        #expect(clue.name == "Jonas")
        #expect(clue.kind == .answeredAfter)
    }

    @Test func answerWithNameInTheMiddleOfTheSentence() throws {
        let lines = [
            SpokenLine(speakerKey: "S4", text: "Wir könnten die Firmendaten optional machen."),
            SpokenLine(speakerKey: "S3", text: "Gute Idee, Jonas, ich mache bis Mittwoch einen Entwurf für das kürzere Formular."),
        ]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S4")
        #expect(clue.name == "Jonas")
    }

    @Test func welcomeNamesThePersonWhoJustArrived() throws {
        let lines = [
            SpokenLine(speakerKey: "S4", text: "Sorry für die Verspätung."),
            SpokenLine(speakerKey: "S2", text: "Willkommen, Paula."),
        ]
        let clue = try #require(finder.clues(in: lines).first)
        #expect(clue.speakerKey == "S4")
        #expect(clue.name == "Paula")
    }

    @Test(arguments: [
        "Okay, dann fangen wir an.",
        "Zum Release: Wir sind feature-complete.",
        "Ich bin der Meinung, dass das reicht.",
        "Ich bin dabei.",
        "Thomas hat gestern gesagt, dass es klappt.",
        "Das hat Miriam schon erledigt.",
        "Genau, Leute, so machen wir das.",
        "This is great, thanks everyone.",
    ])
    func ordinarySentencesGiveNoClue(_ text: String) {
        let lines = [SpokenLine(speakerKey: "S1", text: text), SpokenLine(speakerKey: "S2", text: "Ja.")]
        let clues = finder.clues(in: lines)
        #expect(clues.isEmpty, "unexpected clue \(clues) in “\(text)”")
    }

    @Test func englishPatterns() throws {
        let lines = [
            SpokenLine(speakerKey: "S1", text: "Hi everyone, this is Sarah from the design team."),
            SpokenLine(speakerKey: "S2", text: "Thanks, Sarah. Mark, what do you think?"),
            SpokenLine(speakerKey: "S3", text: "I think it works."),
        ]
        let guesses = NameEvidenceFinder.guesses(from: NameEvidenceFinder(knownNames: ["Mark Lee"]).clues(in: lines))
        #expect(guesses["S1"]?.first?.name == "Sarah")
        #expect(guesses["S3"]?.first?.name == "Mark")
    }

    @Test func guessesAddUpEvidence() throws {
        let lines = [
            SpokenLine(speakerKey: "S2", text: "Ich bin Jonas, ich mache das Backend."),
            SpokenLine(speakerKey: "S1", text: "Danke, Jonas."),
        ]
        let guesses = NameEvidenceFinder.guesses(from: finder.clues(in: lines))
        let best = try #require(guesses["S2"]?.first)
        #expect(best.name == "Jonas")
        #expect(best.score >= 4)
        #expect(best.bestClue.kind == .introduction)
    }
}

@Suite struct SpeakerIdentifierTests {
    let anna = Person(id: "anna", name: "Anna Berger", email: "anna@example.com")
    let jonas = Person(id: "jonas", name: "Jonas Weber")
    let me = Person(id: "me", name: "Lukas", isMe: true)

    func identifier(_ library: VoiceLibrary, attendees: [Attendee] = []) -> SpeakerIdentifier {
        SpeakerIdentifier(library: library, people: [anna, jonas, me], attendees: attendees, thresholds: .standard) { $0 == "S1" ? "Miriam" : $0 }
    }

    @Test func clearVoiceMatchIsAssignedAutomatically() {
        let annaVoice = voice(40)
        let library = VoiceLibrary(voices: ["anna": [annaVoice], "jonas": [voice(41)]])
        let decisions = identifier(library).decide(voices: [VoiceToName(key: "S2", embedding: near(annaVoice, 0.1, seed: 5), talkTime: 30)], guesses: [:])
        #expect(decisions["S2"]?.assignment == .automatic)
        #expect(decisions["S2"]?.personId == "anna")
    }

    @Test func spokenNameOfKnownPersonBecomesSuggestion() {
        let library = VoiceLibrary(voices: ["anna": [voice(42)]])
        let clue = NameClue(speakerKey: "S4", name: "Jonas", kind: .answeredAfter, quote: "Gute Idee, Jonas.", quoteSpeakerKey: "S1")
        let guesses = NameEvidenceFinder.guesses(from: [clue])
        let decision = identifier(library).decide(voices: [VoiceToName(key: "S4", embedding: voice(43), talkTime: 10)], guesses: guesses)["S4"]
        #expect(decision?.assignment == .suggested)
        #expect(decision?.suggestedPersonId == "jonas")
        #expect(decision?.reason == "Miriam: „Gute Idee, Jonas.“")
    }

    @Test func unknownNameUsesTheCalendarSpelling() {
        let clue = NameClue(speakerKey: "S2", name: "Paula", kind: .introduction, quote: "Hier ist Paula.", quoteSpeakerKey: "S2")
        let decision = identifier(VoiceLibrary(), attendees: [Attendee(name: "Paula Schmidt", email: "paula@example.com")])
            .decide(voices: [VoiceToName(key: "S2", embedding: voice(44), talkTime: 10)], guesses: NameEvidenceFinder.guesses(from: [clue]))["S2"]
        #expect(decision?.suggestedName == "Paula Schmidt")
        #expect(decision?.suggestedPersonId == nil)
    }

    @Test func introductionWithAnotherNameOverridesAVoiceMatch() {
        let jonasVoice = voice(49)
        let library = VoiceLibrary(voices: ["jonas": [jonasVoice]])
        let clue = NameClue(speakerKey: "S2", name: "Paula", kind: .introduction, quote: "Hier ist Paula aus dem Support.", quoteSpeakerKey: "S2")
        let decision = identifier(library).decide(
            voices: [VoiceToName(key: "S2", embedding: near(jonasVoice, 0.05, seed: 9), talkTime: 10)],
            guesses: NameEvidenceFinder.guesses(from: [clue])
        )["S2"]
        #expect(decision?.assignment == .suggested)
        #expect(decision?.suggestedName == "Paula")
    }

    @Test func refinementSplitsTwoKnownPeopleAndSeparatesNewcomers() {
        let anna = voice(60), miriam = voice(61), paula = voice(62)
        let library = VoiceLibrary(voices: ["anna": [anna], "miriam": [miriam]])
        let units = [
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(anna, 0.1, seed: 1)),
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(miriam, 0.1, seed: 2)),
            VoiceRefinement.Unit(key: "S1", duration: 5, embedding: near(anna, 0.1, seed: 3)),
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(miriam, 0.1, seed: 4)),
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(paula, 0.1, seed: 5)),
            VoiceRefinement.Unit(key: "S2", duration: 4, embedding: near(miriam, 0.1, seed: 6), introducedNames: ["Paula"]),
        ]
        let keys = VoiceRefinement.refine(units, library: library, thresholds: .standard) { ["anna": "Anna", "miriam": "Miriam"][$0] }
        #expect(keys[0] == keys[2])
        #expect(keys[1] == keys[3])
        #expect(keys[0] != keys[1])
        #expect(keys[4] != keys[0] && keys[4] != keys[1])
        #expect(keys[5] != "S2" || keys.filter { $0 == "S2" }.count == 1)
        #expect(keys[5] != keys[1])
    }

    @Test func aWeakPieceThatIntroducesAnotherNameGetsItsOwnVoice() {
        // The real case from the second test meeting: Paula (unknown) sounds a bit like Miriam (known), and
        // the diarizer put both, and Anna, into one voice. Paula says who she is.
        let anna = voice(64), miriam = voice(65)
        let paula = VoiceMath.normalized(zip(miriam, voice(66)).map { $0 * 0.6 + $1 * 0.8 })
        let library = VoiceLibrary(voices: ["anna": [anna], "miriam": [miriam]])
        let units = [
            VoiceRefinement.Unit(key: "S2", duration: 5.9, embedding: near(anna, 0.1, seed: 11)),
            VoiceRefinement.Unit(key: "S2", duration: 6.3, embedding: paula, introducedNames: ["Paula"]),
            VoiceRefinement.Unit(key: "S2", duration: 6.4, embedding: near(miriam, 0.1, seed: 12)),
            VoiceRefinement.Unit(key: "S2", duration: 4.7, embedding: near(anna, 0.1, seed: 13)),
        ]
        let keys = VoiceRefinement.refine(units, library: library, thresholds: .standard) { ["anna": "Anna Berger", "miriam": "Miriam Okafor"][$0] }
        #expect(keys[0] == "S2" && keys[3] == "S2")
        #expect(keys[2] != "S2")
        #expect(keys[1] != "S2" && keys[1] != keys[2])
    }

    @Test func aWeakPieceIntroducingTheSameNameStays() {
        let anna = voice(67), miriam = voice(68)
        let library = VoiceLibrary(voices: ["anna": [anna], "miriam": [miriam]])
        let weakAnna = VoiceMath.normalized(zip(anna, voice(69)).map { $0 * 0.6 + $1 * 0.8 })
        let units = [
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(anna, 0.1, seed: 14)),
            VoiceRefinement.Unit(key: "S1", duration: 5, embedding: weakAnna, introducedNames: ["Anna"]),
            VoiceRefinement.Unit(key: "S1", duration: 6, embedding: near(anna, 0.1, seed: 15)),
        ]
        let keys = VoiceRefinement.refine(units, library: library, thresholds: .standard) { ["anna": "Anna Berger", "miriam": "Miriam Okafor"][$0] }
        #expect(keys == ["S1", "S1", "S1"])
    }

    @Test func inARoomTheUserIsTheVoiceThatSoundsMostLikeThem() {
        let mine = voice(80), jonas = voice(81)
        let library = VoiceLibrary(voices: ["me": [mine], "jonas": [jonas]])
        // S1 sounds like the user; S2 a little like the user, but more like Jonas (the real case from a
        // room recording with similar voices).
        let jonasLikeMe = VoiceMath.normalized(zip(jonas, mine).map { $0 * 0.85 + $1 * 0.7 })
        let embeddings = ["S1": near(mine, 0.1, seed: 21), "S2": jonasLikeMe]
        #expect(MeetingProcessor.roomVoiceOfUser(embeddings, library: library, me: "me", threshold: 0.72) == "S1")
        #expect(MeetingProcessor.roomVoiceOfUser(["S2": jonasLikeMe], library: library, me: "me", threshold: 0.72) == nil)
        #expect(MeetingProcessor.roomVoiceOfUser(embeddings, library: VoiceLibrary(voices: ["jonas": [jonas]]), me: "me", threshold: 0.72) == nil)
    }

    @Test func refinementLeavesEverythingAloneWithoutKnownVoices() {
        let units = [VoiceRefinement.Unit(key: "S1", duration: 5, embedding: voice(70)), VoiceRefinement.Unit(key: "S2", duration: 5, embedding: voice(71))]
        #expect(VoiceRefinement.refine(units, library: VoiceLibrary(), thresholds: .standard) == ["S1", "S2"])
    }

    @Test func oneOnOneSuggestsTheOnlyInvitee() {
        let decision = identifier(VoiceLibrary(), attendees: [Attendee(name: "Anna Berger", email: "anna@example.com")])
            .decide(voices: [VoiceToName(key: "S1", embedding: voice(45), talkTime: 300)], guesses: [:])["S1"]
        #expect(decision?.assignment == .suggested)
        #expect(decision?.suggestedPersonId == "anna")
    }

    @Test func weakVoiceMatchIsOnlyASuggestion() {
        let annaVoice = voice(46)
        let library = VoiceLibrary(voices: ["anna": [annaVoice]])
        let probe = VoiceMath.normalized(zip(annaVoice, voice(47)).map { $0 * 0.75 + $1 * 0.55 })
        let similarity = VoiceMath.cosine(probe, annaVoice)
        let decision = identifier(library).decide(voices: [VoiceToName(key: "S1", embedding: probe, talkTime: 30)], guesses: [:])["S1"]
        if similarity >= VoiceThresholds.standard.automatic {
            #expect(decision?.assignment == .automatic)
        } else if similarity >= VoiceThresholds.standard.suggestion {
            #expect(decision?.assignment == .suggested)
        } else {
            #expect(decision?.assignment == .unknown)
        }
    }

    @Test func theUserIsNeverMatchedToARemoteVoice() {
        let mine = voice(48)
        let library = VoiceLibrary(voices: ["me": [mine]])
        let decision = identifier(library).decide(voices: [VoiceToName(key: "S1", embedding: mine, talkTime: 30)], guesses: [:])["S1"]
        #expect(decision?.personId != "me")
    }

    @Test func firstNameMatchingPrefersInvitees() {
        let other = Person(id: "anna2", name: "Anna Schulz")
        let identifier = SpeakerIdentifier(library: VoiceLibrary(), people: [anna, other], attendees: [Attendee(name: "Anna Berger", email: "anna@example.com")], thresholds: .standard) { $0 }
        #expect(identifier.person(named: "Anna")?.id == "anna")
        #expect(identifier.person(named: "anna schulz")?.id == "anna2")
    }
}

@Suite struct LiveLineCheckTests {
    let anna = voice(90), thomas = voice(91), jonas = voice(92)
    var library: VoiceLibrary { VoiceLibrary(voices: ["anna": [anna], "thomas": [thomas], "jonas": [jonas]]) }
    let names = ["anna": "Anna Berger", "thomas": "Thomas Klein", "jonas": "Jonas Weber"]

    func check(_ key: String, voice: [Float]?, text: String = "Das sehe ich auch so.", voices: [String: LiveVoice]) -> LiveLineCheck.Outcome {
        LiveLineCheck.check(key: key, voice: voice, text: text, voices: voices, library: library, names: names, me: nil,
                            thresholds: .standard, finder: NameEvidenceFinder(knownNames: Array(names.values)))
    }

    func named(_ key: String, _ personId: String?) -> LiveVoice {
        LiveVoice(key: key, label: "Sprecher \(key.dropFirst())", personId: personId, name: personId.flatMap { names[$0] }, suggestedName: nil, speech: 20)
    }

    @Test func aLineThatSoundsLikeSomeoneElseGoesToThem() {
        // The live diarizer lumped Jonas in with Thomas.
        let voices = ["S1": named("S1", "anna"), "S2": named("S2", "thomas")]
        #expect(check("S2", voice: near(jonas, 0.1, seed: 31), voices: voices) == .newVoice(personId: "jonas", suggestedName: nil))
        var withJonas = voices
        withJonas["S3"] = named("S3", "jonas")
        #expect(check("S2", voice: near(jonas, 0.1, seed: 32), voices: withJonas) == .move(to: "S3"))
    }

    @Test func linesThatFitTheirVoiceStay() {
        let voices = ["S1": named("S1", "anna"), "S2": named("S2", "thomas")]
        #expect(check("S2", voice: near(thomas, 0.1, seed: 33), voices: voices) == .keep)
        // Unclear or missing voice, or a voice without a name yet: nothing to correct.
        #expect(check("S2", voice: VoiceMath.normalized(zip(jonas, voice(93)).map { $0 * 0.6 + $1 * 0.8 }), voices: voices) == .keep)
        #expect(check("S2", voice: nil, voices: voices) == .keep)
        #expect(check("S4", voice: near(jonas, 0.1, seed: 34), voices: ["S4": named("S4", nil)]) == .keep)
    }

    @Test func someoneIntroducingThemselvesByAnotherNameIsSomeoneElse() {
        let voices = ["S1": named("S1", "anna")]
        let text = "Hallo zusammen, hier ist Paula aus dem Support, ich höre heute nur zu."
        #expect(check("S1", voice: near(anna, 0.1, seed: 35), text: text, voices: voices) == .newVoice(personId: nil, suggestedName: "Paula"))
        var withPaula = voices
        withPaula["S5"] = LiveVoice(key: "S5", label: "Sprecher 5", personId: nil, name: nil, suggestedName: "Paula", speech: 6)
        #expect(check("S1", voice: nil, text: text, voices: withPaula) == .move(to: "S5"))
        // Introducing yourself by your own name changes nothing.
        #expect(check("S1", voice: nil, text: "Hier ist Anna, ich bin gleich da.", voices: voices) == .keep)
    }
}
