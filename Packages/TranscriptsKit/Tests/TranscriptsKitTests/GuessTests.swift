import Foundation
import Testing
@testable import TranscriptsKit

private func voice(_ seed: Int) -> [Float] {
    var generator = SeededGenerator(seed: UInt64(seed) &+ 5000)
    return VoiceMath.normalized((0..<256).map { _ in Float.random(in: -1...1, using: &generator) })
}

private func line(of base: [Float], alike: Float = 0.85, seed: Int) -> [Float] {
    let noise = voice(seed + 90_000)
    return VoiceMath.normalized(zip(base, noise).map { $0 * alike + $1 * sqrt(1 - alike * alike) })
}

@Suite struct CandidateTests {
    @Test func closeMatchesAreAllNamed() {
        let matches = [VoiceMatch(personId: "hai", similarity: 0.6, meetings: 2), VoiceMatch(personId: "julian", similarity: 0.55, meetings: 1), VoiceMatch(personId: "sven", similarity: 0.4, meetings: 1)]
        #expect(VoiceLibrary.candidates(matches, thresholds: .standard) == ["hai", "julian"])
        #expect(VoiceLibrary.candidates(matches, thresholds: .standard, rejected: ["hai"]) == ["julian"])
        #expect(VoiceLibrary.candidates([VoiceMatch(personId: "sven", similarity: 0.4, meetings: 1)], thresholds: .standard).isEmpty)
    }

    @Test func unsureVoicesShowWhoTheyMayBe() {
        let hai = Person(id: "hai", name: "Hai"), julian = Person(id: "julian", name: "Julian"), sven = Person(id: "sven", name: "Sven")
        let detail = MeetingDetail(
            meeting: Meeting(id: "m", title: "M"),
            segments: [],
            speakers: [
                MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", personId: "sven", assignment: .confirmed),
                MeetingSpeaker(meetingId: "m", key: "S2", label: "Sprecher 2", assignment: .unknown, candidatePersonIds: ["hai", "julian"]),
                MeetingSpeaker(meetingId: "m", key: "S3", label: "Sprecher 3", assignment: .suggested, suggestedPersonId: "julian", suggestionReason: "Stimme ähnlich wie in einem früheren Meeting"),
                MeetingSpeaker(meetingId: "m", key: "S4", label: "Sprecher 4", assignment: .unknown),
            ],
            people: ["hai": hai, "julian": julian, "sven": sven], summary: nil, actionItems: [], markers: []
        )
        #expect(detail.displayName(for: "S1") == "Sven")
        #expect(detail.displayName(for: "S2") == "Hai oder Julian?")
        #expect(detail.textName(for: "S2") == "Sprecher 2 (vielleicht Hai oder Julian)")
        #expect(detail.displayName(for: "S3") == "Julian?")
        #expect(detail.displayName(for: "S4") == "Sprecher 4")
        #expect(detail.textName(for: "S1") == "Sven")
        #expect(Strings.alternatives(["Hai", "Julian", "Sven"]) == "Hai, Julian oder Sven")
    }

    @Test func aRecheckNamesTheCandidates() {
        let speaker = MeetingSpeaker(meetingId: "m", key: "S2", label: "Sprecher 2", assignment: .unknown)
        let matches = [VoiceMatch(personId: "hai", similarity: 0.6, meetings: 2), VoiceMatch(personId: "julian", similarity: 0.57, meetings: 1)]
        let after = VoiceRecheck.rechecked(speaker, matches: matches, thresholds: .standard)
        #expect(after.assignment == .suggested)
        #expect(after.guesses == ["hai", "julian"])
        // A suggestion from a spoken name stays, the voice adds whom else it could be.
        let named = MeetingSpeaker(meetingId: "m", key: "S3", label: "Sprecher 3", assignment: .suggested, suggestedPersonId: "julian", suggestionReason: "Hai: „Julian, was meinst du?“")
        let kept = VoiceRecheck.rechecked(named, matches: matches, thresholds: .standard)
        #expect(kept.suggestedPersonId == "julian")
        #expect(kept.guesses == ["julian", "hai"])
    }

    @Test func someoneWhoAlreadySpeaksInTheMeetingIsNoGuessForAnotherVoice() {
        let hai = Person(id: "hai", name: "Hai"), julian = Person(id: "julian", name: "Julian")
        let detail = MeetingDetail(
            meeting: Meeting(id: "m", title: "M"),
            segments: [
                Segment(meetingId: "m", speakerKey: "S1", channel: .system, start: 20, end: 24, text: "Ja, das nehme ich."),
                Segment(meetingId: "m", speakerKey: "S1", channel: .system, start: 100, end: 106, text: "Okay, gut."),
            ],
            speakers: [
                MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", assignment: .unknown, sampleStart: 20, sampleEnd: 24, candidatePersonIds: ["hai", "julian"]),
                MeetingSpeaker(meetingId: "m", key: "S2", label: "Sprecher 2", personId: "hai", assignment: .automatic),
                MeetingSpeaker(meetingId: "m", key: "S3", label: "Sprecher 3", assignment: .suggested, suggestedPersonId: "hai", suggestionReason: "Stimme ähnlich wie in einem früheren Meeting"),
            ],
            people: ["hai": hai, "julian": julian], summary: nil, actionItems: [], markers: []
        )
        // Hai speaks as Speaker 2: Speaker 1, which only sounds a little like Hai, is somebody else.
        #expect(detail.guesses(for: detail.speakers[0]).map(\.id) == ["julian"])
        #expect(detail.textName(for: "S1") == "Sprecher 1 (vielleicht Julian)")
        // A voice that sounds enough like Hai to be suggested may be Hai's second voice.
        #expect(detail.guesses(for: detail.speakers[2]).map(\.id) == ["hai"])
        // What the voice sample plays is what is shown with it.
        #expect(detail.sampleLines(of: detail.speakers[0]).map(\.text) == ["Ja, das nehme ich."])
    }

    @Test func aQuoteThatDoesNotSayTheNameIsNoNameThatWasSaid() {
        let matches = [VoiceMatch(personId: "hai", similarity: 0.5, meetings: 4)]
        // A language model took a line of Hai's own for proof that another voice was Hai.
        let misread = MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", assignment: .suggested, suggestedPersonId: "hai", suggestionReason: "„Hai: Ich teile gleich meinen Bildschirm.“")
        let judged = VoiceRecheck.rechecked(misread, matches: matches, thresholds: .standard, named: "Hai")
        #expect(judged.assignment == .unknown)
        #expect(judged.suggestedPersonId == nil)
        #expect(judged.suggestionReason == nil)
        #expect(judged.candidatePersonIds == ["hai"])
        let said = MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", assignment: .suggested, suggestedPersonId: "hai", suggestionReason: "Lukas: „Danke, Hai.“")
        #expect(VoiceRecheck.rechecked(said, matches: matches, thresholds: .standard, named: "Hai").suggestedPersonId == "hai")
    }

    @Test func aSentenceSaysANameInAnyForm() {
        #expect(SpeakerIdentifier.spokenSentence("[12:04] Hai: Ich teile gleich meinen Bildschirm.") == "Ich teile gleich meinen Bildschirm.")
        #expect(SpeakerIdentifier.spokenSentence("Sprecher 2 (vielleicht Hai oder Julian): Danke, Julian.") == "Danke, Julian.")
        #expect(SpeakerIdentifier.spokenSentence("Hai, zwei Sachen: erstens das Backup.") == "Hai, zwei Sachen: erstens das Backup.")
        #expect(SpeakerIdentifier.says("Danke, Hai.", name: "Hai"))
        #expect(SpeakerIdentifier.says("Anno, co myślisz?", name: "Anna Berger"))
        #expect(SpeakerIdentifier.says("Grüße an Herrn Weber.", name: "jonas.weber@example.com"))
        #expect(!SpeakerIdentifier.says("Ich teile gleich meinen Bildschirm.", name: "Hai"))
        #expect(!SpeakerIdentifier.says("Komm doch mal rüber.", name: "jonas.weber@example.com"))
    }
}

@Suite struct StrayLineTests {
    /// Hai's speaker holds three lines in Julian's voice; Julian is confirmed in the same meeting.
    func meeting() throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "hai", name: "Hai"))
        try database.save(Person(id: "julian", name: "Julian"))
        try database.save(Meeting(id: "a", title: "Sync", status: .ready))
        let hai = voice(1), julian = voice(2)
        var segments: [Segment] = []
        for index in 0..<8 {
            segments.append(Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: Double(index) * 10, end: Double(index) * 10 + 8, text: "Hai \(index)", embedding: line(of: hai, seed: index).embeddingData))
        }
        for index in 0..<3 {
            segments.append(Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 100 + Double(index) * 10, end: 106 + Double(index) * 10, text: "Julian bei Hai \(index)", embedding: line(of: julian, seed: 20 + index).embeddingData))
        }
        for index in 0..<6 {
            segments.append(Segment(meetingId: "a", speakerKey: "S2", channel: .system, start: 200 + Double(index) * 10, end: 208 + Double(index) * 10, text: "Julian \(index)", embedding: line(of: julian, seed: 40 + index).embeddingData))
        }
        try database.replaceTranscript(meetingId: "a", segments: segments, speakers: [
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", personId: "hai", assignment: .confirmed),
            MeetingSpeaker(meetingId: "a", key: "S2", label: "Sprecher 2", personId: "julian", assignment: .confirmed),
        ])
        return database
    }

    @Test func linesInTheWrongPlaceMoveAndCanBeSentBack() throws {
        let database = try meeting()
        let library = VoiceLibrary(samples: try database.voiceSamples())
        #expect(try VoiceRecheck.moveStrayLines(database: database, library: library, thresholds: .standard) == 1)

        let detail = try #require(try database.detail(of: "a"))
        let moved = detail.segments.filter { $0.text.hasPrefix("Julian bei Hai") }
        #expect(moved.allSatisfy { $0.speakerKey == "S2" && $0.placement == .app && $0.movedFromKey == "S1" })
        // Moved by the app, they count as recognised speech only.
        let samples = try database.voiceSamples().filter { sample in moved.contains { $0.id == sample.segmentId } }
        #expect(samples.allSatisfy { $0.source == .automatic })
        // Nothing more to move.
        #expect(try VoiceRecheck.strayMoves(database: database, library: VoiceLibrary(samples: try database.voiceSamples()), thresholds: .standard).isEmpty)

        // Sent back: they return to Hai and stay there.
        try database.returnMovedLines(moved.compactMap(\.id), in: "a")
        let back = try #require(try database.detail(of: "a")).segments.filter { $0.text.hasPrefix("Julian bei Hai") }
        #expect(back.allSatisfy { $0.speakerKey == "S1" && $0.placement == .user })
        #expect(try VoiceRecheck.strayMoves(database: database, library: VoiceLibrary(samples: try database.voiceSamples()), thresholds: .standard).isEmpty)
    }

    @Test func keptLinesStayWhereTheyAre() throws {
        let database = try meeting()
        let lines = try #require(try database.detail(of: "a")).segments.filter { $0.text.hasPrefix("Julian bei Hai") }.compactMap(\.id)
        try database.keepLines(lines)
        let kept = try #require(try database.detail(of: "a")).segments.filter { $0.id.map(lines.contains) ?? false }
        #expect(kept.count == 3 && kept.allSatisfy { $0.speakerKey == "S1" && $0.placement == .user })
        // The user said they are Hai's: the app no longer moves them to Julian.
        #expect(try VoiceRecheck.strayMoves(database: database, library: VoiceLibrary(samples: try database.voiceSamples()), thresholds: .standard).isEmpty)
    }

    @Test func acceptedMovesCountAsTheUsersWord() throws {
        let database = try meeting()
        try VoiceRecheck.moveStrayLines(database: database, library: VoiceLibrary(samples: try database.voiceSamples()), thresholds: .standard)
        let moved = try #require(try database.detail(of: "a")).segments.filter { $0.placement == .app }.compactMap(\.id)
        try database.acceptMovedLines(moved)
        let samples = try database.voiceSamples().filter { $0.segmentId.map(moved.contains) ?? false }
        #expect(samples.count == 3 && samples.allSatisfy { $0.source == .confirmed })
    }

    @Test func theUsersVoiceIsNeverAMoveTarget() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "me", name: "Lukas", isMe: true))
        try database.save(Meeting(id: "a", title: "Sync", status: .ready))
        let mine = voice(3), other = voice(4)
        var segments = (0..<6).map { Segment(meetingId: "a", speakerKey: "me", channel: .microphone, start: Double($0) * 10, end: Double($0) * 10 + 8, text: "Ich \($0)", embedding: line(of: mine, seed: $0).embeddingData) }
        segments += (0..<6).map { Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 100 + Double($0) * 10, end: 108 + Double($0) * 10, text: "Andere \($0)", embedding: line(of: other, seed: 30 + $0).embeddingData) }
        segments += (0..<3).map { Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 200 + Double($0) * 10, end: 206 + Double($0) * 10, text: "Ich im Call \($0)", embedding: line(of: mine, seed: 50 + $0).embeddingData) }
        try database.replaceTranscript(meetingId: "a", segments: segments, speakers: [
            MeetingSpeaker(meetingId: "a", key: "me", label: Strings.meLabel, personId: "me", assignment: .confirmed, channel: .microphone),
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1"),
        ])
        #expect(try VoiceRecheck.strayMoves(database: database, library: VoiceLibrary(samples: try database.voiceSamples()), thresholds: .standard).isEmpty)
    }
}

@Suite struct NamingTests {
    @MainActor @Test func voicesOfTheOpenMeetingComeFirst() throws {
        let database = try AppDatabase.inMemory()
        let model = AppModel(database: database, settings: AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!), secrets: MemorySecretStore(), isDemo: true)
        for (id, day) in [("old", -2.0), ("new", -1.0)] {
            try database.save(Meeting(id: id, title: id, startedAt: Date().addingTimeInterval(day * 86_400), status: .ready))
            try database.replaceTranscript(meetingId: id, segments: [Segment(meetingId: id, speakerKey: "S1", channel: .system, start: 0, end: 10, text: "Hallo")],
                                           speakers: [MeetingSpeaker(meetingId: id, key: "S1", label: "Sprecher 1", talkTime: 10)])
        }
        #expect(model.voicesToName().map(\.speaker.meetingId) == ["new", "old"])
        #expect(model.voicesToName(first: "old").map(\.speaker.meetingId) == ["old", "new"])
        model.ignoreVoice(try #require(try database.detail(of: "old")?.speakers.first))
        #expect(model.voicesToName().map(\.speaker.meetingId) == ["new"])
    }

    @MainActor @Test func aNameFromTheSummaryNeedsASentenceThatSaysIt() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "hai", name: "Hai"))
        try database.save(Person(id: "julian", name: "Julian"))
        try database.save(Meeting(id: "a", title: "Weekly", status: .ready))
        try database.replaceTranscript(meetingId: "a", segments: [
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 5, text: "Ja, das nehme ich."),
            Segment(meetingId: "a", speakerKey: "S2", channel: .system, start: 6, end: 11, text: "Ich teile gleich meinen Bildschirm."),
            Segment(meetingId: "a", speakerKey: "S3", channel: .system, start: 12, end: 17, text: "Klar, mache ich."),
        ], speakers: [
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", talkTime: 5, candidatePersonIds: ["hai"]),
            MeetingSpeaker(meetingId: "a", key: "S2", label: "Sprecher 2", personId: "hai", assignment: .automatic, talkTime: 5),
            MeetingSpeaker(meetingId: "a", key: "S3", label: "Sprecher 3", talkTime: 5),
        ])
        let model = AppModel(database: database, settings: AppSettings(defaults: UserDefaults(suiteName: "TranscriptsTests-\(UUID().uuidString)")!), secrets: MemorySecretStore(), isDemo: true)
        model.applyNameHints([
            // A line of Hai's own proves nothing about Speaker 1.
            SpeakerNameHint(speakerLabel: "Sprecher 1 (vielleicht Hai)", name: "Hai", evidence: "Hai: Ich teile gleich meinen Bildschirm."),
            SpeakerNameHint(speakerLabel: "Sprecher 3", name: "Julian", evidence: "[00:11] Lukas: Julian, machst du das?"),
        ], in: try #require(try database.detail(of: "a")))
        let detail = try #require(try database.detail(of: "a"))
        let first = try #require(detail.speaker(for: "S1"))
        #expect(first.assignment == .unknown)
        #expect(detail.speaker(for: "S3")?.suggestedPersonId == "julian")
        #expect(detail.speaker(for: "S3")?.suggestionReason == "„Julian, machst du das?“")
        // Hai has a voice in this meeting: Speaker 1 isn't asked about as Hai, here or among all voices to name.
        #expect(detail.guesses(for: first).isEmpty)
        #expect(try database.voiceReviews().first { $0.speaker.key == "S1" }?.guesses == [])
    }
}

@Suite struct MoveTargetTests {
    @Test func movedLinesJoinTheVoiceAlreadyGuessedToBeThatPerson() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "jonas", name: "Jonas"))
        try database.save(Meeting(id: "a", title: "Sync", status: .ready))
        try database.replaceTranscript(meetingId: "a", segments: [
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 8, text: "Anna"),
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 10, end: 18, text: "Jonas bei Anna"),
            Segment(meetingId: "a", speakerKey: "S4", channel: .system, start: 20, end: 28, text: "Jonas"),
        ], speakers: [
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1"),
            MeetingSpeaker(meetingId: "a", key: "S4", label: "Sprecher 4", assignment: .suggested, suggestedPersonId: "jonas"),
        ])
        let line = try #require(try database.detail(of: "a")?.segments[1].id)
        #expect(try database.moveLines([line], in: "a", toPerson: "jonas", byApp: true) == "S4")
        let detail = try #require(try database.detail(of: "a"))
        #expect(detail.speakers.count == 2)
        #expect(detail.speaker(for: "S4")?.assignment == .suggested)
    }
}
