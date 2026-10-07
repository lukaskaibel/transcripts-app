import Foundation
import Testing
@testable import TranscriptsKit

private func voice(_ seed: Int) -> [Float] {
    var generator = SeededGenerator(seed: UInt64(seed) &+ 1000)
    return VoiceMath.normalized((0..<256).map { _ in Float.random(in: -1...1, using: &generator) })
}

/// Another line of the same voice: `alike` is roughly the cosine similarity to the voice (lines of one real
/// voice are about 0.6–0.9 alike).
private func line(of base: [Float], alike: Float = 0.8, seed: Int) -> [Float] {
    let noise = voice(seed + 50_000)
    let weight = sqrt(max(0, 1 - alike * alike))
    return VoiceMath.normalized(zip(base, noise).map { $0 * alike + $1 * weight })
}

private func sample(_ person: String, _ embedding: [Float], seconds: Double = 8, source: VoiceSample.Source = .confirmed, meeting: String = "m1", id: String = UUID().uuidString, ignored: Bool = false) -> VoiceSample {
    VoiceSample(id: id, personId: person, embedding: embedding, duration: seconds, source: source, meetingId: meeting, segmentId: Int64.random(in: 1...1_000_000), start: 0, ignored: ignored)
}

@Suite struct VoiceClusteringTests {
    @Test func linesOfTwoVoicesFallIntoTwoGroups() {
        let anna = voice(1), thomas = voice(2)
        let vectors = (0..<8).map { line(of: anna, seed: $0) } + (0..<5).map { line(of: thomas, seed: 100 + $0) }
        let (groups, unattached) = VoiceClustering.groups(vectors, durations: Array(repeating: 6, count: 13))
        #expect(groups.count == 2)
        #expect(Set(groups[0]) == Set(0..<8))
        #expect(Set(groups[1]) == Set(8..<13))
        #expect(unattached.isEmpty)
    }

    @Test func shortLinesJoinTheirGroupOrStayOut() {
        let anna = voice(3)
        var vectors = (0..<6).map { line(of: anna, seed: $0) }
        vectors.append(line(of: anna, alike: 0.6, seed: 20))  // a short line of Anna
        vectors.append(voice(4))  // a short line of nobody known
        let durations: [Double] = Array(repeating: 6, count: 6) + [1.2, 1.2]
        let (groups, unattached) = VoiceClustering.groups(vectors, durations: durations)
        #expect(groups.count == 1)
        #expect(groups[0].contains(6))
        #expect(unattached == [7])
    }

    @Test func theMapSeparatesVoices() {
        let anna = voice(5), thomas = voice(6)
        let vectors = (0..<6).map { line(of: anna, seed: $0) } + (0..<6).map { line(of: thomas, seed: 200 + $0) }
        let points = VoiceMath.projection(vectors)
        #expect(points.count == 12)
        #expect(points.allSatisfy { abs($0.x) <= 1.0001 && abs($0.y) <= 1.0001 })
        let first = points[0..<6].map(\.x), second = points[6..<12].map(\.x)
        // One voice on each side of the first direction.
        #expect((first.allSatisfy { $0 > 0 } && second.allSatisfy { $0 < 0 }) || (first.allSatisfy { $0 < 0 } && second.allSatisfy { $0 > 0 }))
    }
}

@Suite struct VoiceProfileTests {
    /// The heart of it: one wrong line under a name does not make the app hear that name in someone else.
    @Test func aWrongLineIsAStrayAndRecognisesNobody() throws {
        let anna = voice(10), hai = voice(11)
        var samples = (0..<10).map { sample("anna", line(of: anna, seed: $0), meeting: "m\($0 % 3)") }
        samples.append(sample("anna", line(of: hai, alike: 0.9, seed: 30), seconds: 5, meeting: "m9"))
        let library = VoiceLibrary(samples: samples)
        let profile = try #require(library.profiles["anna"])
        #expect(profile.groups.filter(\.isTrusted).count == 1)
        #expect(profile.groups.contains { !$0.isTrusted } || !profile.strays.isEmpty)

        let haiLater = line(of: hai, alike: 0.9, seed: 31)
        let match = try #require(library.rank(haiLater).first)
        #expect(match.similarity < VoiceThresholds.standard.suggestion)
        // Anna herself is still recognised.
        #expect(try #require(library.rank(line(of: anna, alike: 0.9, seed: 32)).first).similarity > VoiceThresholds.standard.automatic)
    }

    @Test func aPersonMayHaveTwoVoices() throws {
        // The same person with two microphones: both voices count, and the app asks whether it's two people.
        let headset = voice(12), laptop = voice(13)
        let samples = (0..<6).map { sample("lukas", line(of: headset, seed: $0), meeting: "a\($0)") }
            + (0..<6).map { sample("lukas", line(of: laptop, seed: 300 + $0), meeting: "b\($0)") }
        let profile = VoiceProfile(personId: "lukas", samples: samples)
        #expect(profile.groups.filter(\.isTrusted).count == 2)
        #expect(profile.possibleSplit != nil)
        let library = VoiceLibrary(samples: samples)
        #expect(try #require(library.rank(line(of: laptop, alike: 0.9, seed: 40)).first).similarity > 0.8)
        #expect(VoiceProfile(personId: "lukas", samples: Array(samples.prefix(6))).possibleSplit == nil)
    }

    @Test func recognisedLinesRefineButNeverDefineAVoice() throws {
        let anna = voice(14), stranger = voice(15)
        let onlyRecognised = VoiceProfile(personId: "x", samples: (0..<5).map { sample("x", line(of: stranger, seed: $0), source: .automatic) })
        #expect(!onlyRecognised.hasVoice)

        let samples = (0..<4).map { sample("anna", line(of: anna, seed: $0)) }
            + [sample("anna", line(of: anna, seed: 50), source: .automatic, meeting: "later")]
            + [sample("anna", line(of: stranger, seed: 51), source: .automatic, meeting: "wrong")]
        let profile = VoiceProfile(personId: "anna", samples: samples)
        let main = try #require(profile.groups.first)
        #expect(main.recognizedSpeech == 8)
        #expect(profile.strays.count == 1)
        // A meeting is never judged by what it added itself.
        #expect(main.centroid(excluding: "later") != main.centroid)
        #expect(main.centroid(excluding: "elsewhere") == main.centroid)
    }

    @Test func ignoredLinesDoNotCount() {
        let anna = voice(16), hai = voice(17)
        let samples = (0..<6).map { sample("anna", line(of: anna, seed: $0)) }
            + (0..<6).map { sample("anna", line(of: hai, seed: 400 + $0), ignored: true) }
        let library = VoiceLibrary(samples: samples)
        #expect(library.profiles["anna"]?.ignored.count == 6)
        #expect((library.rank(line(of: hai, alike: 0.9, seed: 60)).first?.similarity ?? 0) < VoiceThresholds.standard.suggestion)
    }

    @Test func meetingsAreCounted() {
        let anna = voice(18)
        let samples = (0..<6).map { sample("anna", line(of: anna, seed: $0), meeting: "m\($0 % 2)") }
        let match = VoiceLibrary(samples: samples).rank(anna).first
        #expect(match?.meetings == 2)
    }
}

@Suite struct VoiceRecheckTests {
    func speaker(_ assignment: MeetingSpeaker.Assignment, person: String? = nil, suggested: String? = nil, reason: String? = nil) -> MeetingSpeaker {
        MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", personId: person, assignment: assignment, suggestedPersonId: suggested, suggestionReason: reason)
    }

    let clear = [VoiceMatch(personId: "hai", similarity: 0.86, meetings: 2), VoiceMatch(personId: "sven", similarity: 0.3, meetings: 1)]
    let weak = [VoiceMatch(personId: "hai", similarity: 0.6, meetings: 2)]

    @Test func anAutomaticNameThatNoLongerHoldsIsWithdrawn() {
        let before = speaker(.automatic, person: "sven")
        let now = VoiceRecheck.rechecked(before, matches: clear, thresholds: .standard)
        #expect(now.assignment == .automatic)
        #expect(now.personId == "hai")
        let gone = VoiceRecheck.rechecked(before, matches: [], thresholds: .standard)
        #expect(gone.assignment == .unknown)
        #expect(gone.personId == nil)
        let doubtful = VoiceRecheck.rechecked(before, matches: weak, thresholds: .standard)
        #expect(doubtful.assignment == .suggested)
        #expect(doubtful.suggestedPersonId == "hai")
        #expect(doubtful.suggestionReason == "Stimme ähnlich wie in 2 früheren Meetings")
    }

    @Test func confirmedVoicesAndSpokenNamesStay() {
        let confirmed = speaker(.confirmed, person: "sven")
        #expect(VoiceRecheck.rechecked(confirmed, matches: clear, thresholds: .standard) == confirmed)
        let named = speaker(.suggested, suggested: "julian", reason: "Sprecher 1: „Julian, versuch mal …“")
        let kept = VoiceRecheck.rechecked(named, matches: clear, thresholds: .standard)
        #expect(kept.assignment == .suggested)
        #expect(kept.suggestedPersonId == "julian")
        #expect(kept.suggestionReason == named.suggestionReason)
    }

    @Test func rejectedPeopleAreSkipped() {
        var unknown = speaker(.unknown)
        unknown.rejectedPersonIds = ["hai"]
        let now = VoiceRecheck.rechecked(unknown, matches: clear, thresholds: .standard)
        #expect(now.personId != "hai" && now.suggestedPersonId != "hai")
    }
}

@Suite struct CarryOverTests {
    func line(_ key: String, _ start: Double, _ end: Double) -> DraftLine {
        DraftLine(speakerKey: key, channel: .system, start: start, end: end, words: [TimedWord(text: "x", start: start, end: end)])
    }

    @Test func confirmedNamesStayWithTheSameSpeech() {
        let previous = MeetingDetail(
            meeting: Meeting(id: "m", title: "M"),
            segments: [
                Segment(meetingId: "m", speakerKey: "S2", channel: .system, start: 0, end: 12, text: "a"),
                Segment(meetingId: "m", speakerKey: "S2", channel: .system, start: 20, end: 30, text: "b", voiceIgnored: true),
                Segment(meetingId: "m", speakerKey: "S1", channel: .system, start: 40, end: 50, text: "c"),
            ],
            speakers: [
                MeetingSpeaker(meetingId: "m", key: "S2", label: "Sprecher 2", personId: "hai", assignment: .confirmed),
                MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", personId: "sven", assignment: .automatic),
            ],
            people: [:], summary: nil, actionItems: [], markers: []
        )
        // The new pass split Hai into two voices and numbered differently.
        var lines = [line("S1", 0, 12), line("S3", 20, 30), line("S2", 40, 50)]
        let carried = MeetingProcessor.carriedOver(from: previous, to: &lines)
        #expect(carried.assignments["S1"] == .some("hai"))
        #expect(lines.map(\.speakerKey) == ["S1", "S1", "S2"])
        // Only confirmed names carry over; automatic ones are judged afresh.
        #expect(carried.assignments["S2"] == nil)
        #expect(carried.ignoredLines == [1])
    }
}

@Suite struct LiveEchoTests {
    @Test func theCallThroughTheSpeakersIsNotTheUser() {
        // Values from the first real meetings: echo of the call, the user, and the user over the call.
        #expect(LiveLineCheck.isEchoOfCall(user: 0.15, call: 0.67))
        #expect(!LiveLineCheck.isEchoOfCall(user: 0.81, call: 0.24))
        #expect(!LiveLineCheck.isEchoOfCall(user: 0.45, call: 0.6))
        #expect(!LiveLineCheck.isEchoOfCall(user: 0.3, call: 0.4))
        // Without the user's voice only a very clear case counts.
        #expect(!LiveLineCheck.isEchoOfCall(user: nil, call: 0.6))
        #expect(LiveLineCheck.isEchoOfCall(user: nil, call: 0.75))
    }
}

@Suite struct SpeakerVoicesTests {
    func lines(_ key: String, _ voices: [[Float]], from start: Double = 0, seconds: Double = 9) -> [Segment] {
        voices.enumerated().map { index, voice in
            var segment = Segment(meetingId: "m", speakerKey: key, channel: .system, start: start + Double(index) * 10, end: start + Double(index) * 10 + seconds, text: "Zeile \(index)", embedding: voice.embeddingData)
            segment.id = Int64(start) + Int64(index) + 1
            return segment
        }
    }

    @Test func onlyClearlyOtherVoicesWithRealSpeechAreOffered() {
        let anna = voice(70), jonas = voice(71)
        // Anna, then Jonas for 18 s in her speaker: offered.
        let mixed = lines("S1", (0..<5).map { line(of: anna, seed: $0) }) + lines("S1", [line(of: jonas, seed: 10), line(of: jonas, seed: 11)], from: 100)
        #expect(SpeakerVoices.notable(SpeakerVoices.groups(of: mixed)["S1"] ?? []).count == 2)
        // A few seconds of someone else: noise, not offered.
        let short = lines("S1", (0..<5).map { line(of: anna, seed: $0) }) + lines("S1", [line(of: jonas, seed: 12)], from: 100, seconds: 6)
        #expect(SpeakerVoices.notable(SpeakerVoices.groups(of: short)["S1"] ?? []).isEmpty)
        // Ignored lines play no part.
        var ignored = mixed
        for index in ignored.indices where index >= 5 { ignored[index].voiceIgnored = true }
        #expect(SpeakerVoices.notable(SpeakerVoices.groups(of: ignored)["S1"] ?? []).isEmpty)
    }
}

@Suite struct ReviewCaseTests {
    /// One long line of someone else in a confirmed speaker is no voice of its own.
    @Test func oneLongForeignLineRecognisesNobody() throws {
        let anna = voice(80), bob = voice(81)
        let samples = (0..<10).map { sample("anna", line(of: anna, seed: $0), seconds: 3) } + [sample("anna", line(of: bob, alike: 0.9, seed: 20), seconds: 25)]
        let library = VoiceLibrary(samples: samples)
        let best = library.rank(line(of: bob, alike: 0.9, seed: 21)).first?.similarity ?? 0
        #expect(best < VoiceThresholds.standard.automatic)
    }

    @Test func oldAveragesFollowCorrections() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "sven", name: "Sven"))
        try database.save(Person(id: "hai", name: "Hai"))
        try database.save(Meeting(id: "a", title: "Alt", status: .ready))
        try database.replaceTranscript(meetingId: "a", segments: [Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 5, text: "Hallo")],
                                       speakers: [MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", personId: "sven", assignment: .confirmed)])
        try database.save(Voiceprint(personId: "sven", embedding: voice(82).embeddingData, meetingId: "a", duration: 30))
        #expect(try database.voiceSamples().map(\.personId) == ["sven"])
        // Corrected: the old average of that meeting no longer speaks for Sven.
        let speaker = try #require(try database.detail(of: "a")?.speakers.first)
        try database.assign(speaker, to: "hai")
        #expect(try database.voiceSamples().isEmpty)
    }

    @Test func movingLinesNeverConfirmsAGuess() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "anna", name: "Anna"))
        try database.save(Meeting(id: "a", title: "Sync", status: .ready))
        try database.replaceTranscript(meetingId: "a", segments: [
            Segment(meetingId: "a", speakerKey: "S1", channel: .system, start: 0, end: 5, text: "Eins"),
            Segment(meetingId: "a", speakerKey: "S2", channel: .system, start: 5, end: 10, text: "Zwei"),
        ], speakers: [
            MeetingSpeaker(meetingId: "a", key: "S1", label: "Sprecher 1", personId: "anna", assignment: .automatic),
            MeetingSpeaker(meetingId: "a", key: "S2", label: "Sprecher 2"),
        ])
        let line = try #require(try database.detail(of: "a")?.segments.last?.id)
        let key = try database.moveLines([line], in: "a", toPerson: "anna")
        let detail = try #require(try database.detail(of: "a"))
        #expect(key != "S1")
        #expect(detail.speaker(for: "S1")?.assignment == .automatic)
        #expect(detail.speaker(for: key ?? "")?.assignment == .confirmed)
    }

    @Test func rejectionsAndSeparatedMicrophoneVoicesSurviveReprocessing() {
        let previous = MeetingDetail(
            meeting: Meeting(id: "m", title: "M"),
            segments: [
                Segment(meetingId: "m", speakerKey: "S1", channel: .system, start: 0, end: 20, text: "a"),
                Segment(meetingId: "m", speakerKey: "me", channel: .microphone, start: 30, end: 40, text: "b"),
                Segment(meetingId: "m", speakerKey: "S2", channel: .microphone, start: 50, end: 60, text: "c"),
            ],
            speakers: [
                MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", assignment: .unknown, rejectedPersonIds: ["jonas"]),
                MeetingSpeaker(meetingId: "m", key: "me", label: Strings.me, personId: "me", assignment: .confirmed, channel: .microphone),
                MeetingSpeaker(meetingId: "m", key: "S2", label: "Sprecher 2", personId: "hai", assignment: .confirmed, channel: .microphone),
            ],
            people: [:], summary: nil, actionItems: [], markers: []
        )
        func draft(_ key: String, _ channel: Channel, _ start: Double, _ end: Double) -> DraftLine {
            DraftLine(speakerKey: key, channel: channel, start: start, end: end, words: [TimedWord(text: "x", start: start, end: end)])
        }
        var lines = [draft("S1", .system, 0, 20), draft("me", .microphone, 30, 40), draft("me", .microphone, 50, 60)]
        let carried = MeetingProcessor.carriedOver(from: previous, to: &lines)
        #expect(carried.rejections["S1"] == ["jonas"])
        #expect(lines.map(\.speakerKey) == ["S1", "me", "S2"])
        #expect(carried.assignments["S2"] == .some("hai"))
    }
}
